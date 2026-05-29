#!/usr/bin/env bash
#
# Tutorial provision script for "Свой чат-бот с open-source LLM"
# (slug: chatbot; reuses the open-webui Vast.ai template).
#
# Runs on the GPU instance after the container starts. The customer app's
# onstart wrapper exports two env vars before invoking us:
#
#   CC_PROVISION_URL   POST endpoint for stage updates
#                      (e.g. https://app.cloudcompute.ru/api/agent/provision)
#   CC_AGENT_TOKEN     bearer token authenticating us to that endpoint
#
# Both are optional — if absent, report_stage is a silent no-op so the
# script still works for local manual testing (e.g. via `bash provision.sh`
# inside a fresh container).
#
# Stage IDs reported here MUST match the application's manifest entry in
# `config/applications.php` on the customer app side. Currently:
#
#   ensure_ollama      Ollama API answering on :11434
#   ensure_open_webui  open-webui binary present, port :7500 reachable
#   download_model     `ollama pull` of the default model
#   start_server       Open WebUI serves HTTP (final port check)
#
# install_runtime was split into ensure_ollama + ensure_open_webui on
# 2026-05-29 because the latter genuinely takes 5–15 min on a fresh Vast
# image (pip-installs ~1 GB of deps) and a single opaque stage felt
# broken to customers. The ensure_open_webui stage emits progress_pct
# at coarse intervals so the wizard bar moves during the wait.
#
# stdout/stderr go to /var/log/cc-provision.log (the onstart wrapper sets
# this up via `nohup ... > /var/log/cc-provision.log 2>&1 &`).

# -E so the ERR trap propagates into functions and subshells; without
# this the trap only catches errors at the top level and silent crashes
# from inside while-read pipelines (like the one in download_model below)
# would slip past the safety net.
set -Eeuo pipefail

CC_PROVISION_URL="${CC_PROVISION_URL:-}"
CC_AGENT_TOKEN="${CC_AGENT_TOKEN:-}"

# Default model. llama3.1:8b is the v1 pick: ~5 GB on disk, fits in 12 GB
# VRAM, and gives a working chat without a 10-minute wait on first connect.
# The Vast template itself exports OLLAMA_MODEL=qwen3.5:35b, which turns the
# "quick start" path into a 23 GB download and can push 24 GB cards into a
# slow first boot. Ignore the template default and use our app default unless
# we explicitly pass a CloudCompute override.
OLLAMA_MODEL="${CC_OLLAMA_MODEL:-llama3.1:8b}"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
OPEN_WEBUI_PORT="${OPEN_WEBUI_PORT:-7500}"

# /root is always present on Vast containers; /workspace is template-
# dependent and is *missing* on vastai/openwebui:v0.8.12. The previous
# revision of this script wrote the WebUI secret to /workspace/... and
# the redirect crashed before any further stage report could fire,
# leaving the wizard frozen on the first stage indefinitely (incident
# 2026-05-29).
OPEN_WEBUI_HOME="${OPEN_WEBUI_HOME:-/root/cc-open-webui}"
OPEN_WEBUI_VENV="${OPEN_WEBUI_VENV:-${OPEN_WEBUI_HOME}/venv}"
OPEN_WEBUI_SECRET_FILE="${OPEN_WEBUI_SECRET_FILE:-${OPEN_WEBUI_HOME}/secret}"
mkdir -p "$OPEN_WEBUI_HOME"

# --- helpers --------------------------------------------------------------

# Stage the script is currently executing. The ERR trap surfaces this back
# to the API so the wizard can show a real error instead of a stage that
# just never advances when something blows up underneath us.
CC_CURRENT_STAGE="bootstrap"

# report_stage <json-payload>
#
# Best-effort POST to /api/agent/provision. Failures (network blips, 401,
# 422 from misconstructed payloads) are swallowed: a missed update is far
# preferable to crashing provisioning halfway through. The frontend's
# provision_marker ready-check on the entrypoint port is the ultimate
# gate, so even if every single report_stage call fails the user still
# gets a working session as long as Open WebUI itself comes up.
report_stage() {
    if [ -z "$CC_PROVISION_URL" ] || [ -z "$CC_AGENT_TOKEN" ]; then
        return 0
    fi
    curl -fsS \
        -X POST "$CC_PROVISION_URL" \
        -H "Authorization: Bearer $CC_AGENT_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$1" \
        --max-time 5 \
        >/dev/null 2>&1 || true
}

log() {
    echo "[cc-provision] $*"
}

# Final stage report on unexpected failure. Without this, an early-exit
# from set -e leaves the wizard sitting on whatever stage was most-recently
# reported — exactly what happened on 2026-05-29 when /workspace/ didn't
# exist and the redirect crashed before any further report had a chance
# to fire. Best-effort: if even this report fails we still exit with
# the original code so the onstart wrapper sees the failure too.
on_error() {
    local rc=$?
    local line=${BASH_LINENO[0]:-?}
    log "ERR trap fired at line $line (stage=$CC_CURRENT_STAGE, rc=$rc)"
    local msg="Скрипт упал на этапе ${CC_CURRENT_STAGE} (строка ${line}, код ${rc}). См. /var/log/cc-provision.log."
    report_stage "{\"stage\":\"${CC_CURRENT_STAGE}\",\"message\":\"${msg}\"}"
    exit "$rc"
}
trap on_error ERR

# port_responds <port>
#
# True if something is bound on `localhost:<port>` and answering HTTP.
# We use this instead of a raw TCP-bind check because Open WebUI takes
# a few extra seconds after binding the socket before its router is
# ready to actually serve requests, and we want to gate on the latter.
port_responds() {
    curl -fsS --max-time 1 "http://127.0.0.1:${1}/" >/dev/null 2>&1
}

# --- stage 1: ensure_ollama ----------------------------------------------
#
# The Vast `open-webui` template has Ollama preinstalled. In practice the
# multi-ENTRYPOINT collision with Jupyter means it sometimes auto-starts
# (current observation: yes, ollama listens on :11434 by the time we get
# here), and sometimes won't on future template revisions. We defensively
# verify reachability and start it if missing.

CC_CURRENT_STAGE="ensure_ollama"
log "stage: ensure_ollama"
report_stage '{"stage":"ensure_ollama"}'

if ! curl -fsS --max-time 2 "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
    if ! command -v ollama >/dev/null 2>&1; then
        log "ollama binary not found; installing from upstream"
        curl -fsSL https://ollama.com/install.sh | sh
    fi
    log "starting ollama serve"
    # We can't rely on systemd inside a Vast container, so just nohup it.
    # OLLAMA_HOST=0.0.0.0 would expose the inference API publicly; we
    # leave it on the loopback default since Open WebUI is the only
    # local consumer and the customer reaches Ollama through it.
    nohup ollama serve > /var/log/ollama.log 2>&1 &
    for _ in $(seq 1 20); do
        if curl -fsS --max-time 1 "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
fi

if ! curl -fsS --max-time 2 "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
    log "ollama did not become reachable on ${OLLAMA_HOST} within 20s"
    report_stage '{"stage":"ensure_ollama","message":"Ollama не запустился. См. /var/log/ollama.log."}'
    exit 1
fi

# --- stage 2: ensure_open_webui ------------------------------------------
#
# The vastai/openwebui:v0.8.12 template does NOT ship a runnable
# open-webui binary (verified 2026-05-29 via SSH: `which open-webui`
# empty, `python3 -c 'import open_webui'` ModuleNotFoundError, `find /`
# turned up nothing). The image name implies otherwise — what actually
# ships is Ollama + the supporting CUDA stack — so we always install
# Open WebUI fresh into our own venv.
#
# pip install open-webui pulls ~1 GB of deps (chromadb,
# sentence-transformers, fastapi, langchain bits, etc.) and takes
# 5–15 min on a typical Vast machine. We emit progress_pct at coarse
# milestones so the wizard bar moves during the wait instead of looking
# frozen. A background ticker advances 35→85% during the long pip step
# and we jump to 90% once pip exits 0.

CC_CURRENT_STAGE="ensure_open_webui"
log "stage: ensure_open_webui"
report_stage '{"stage":"ensure_open_webui","progress_pct":0}'

INSTALL_LOG=/var/log/open-webui-install.log
: > "$INSTALL_LOG"

OPEN_WEBUI_BIN=""

# Fast paths first. If a future template variant ships open-webui as a
# real binary, or if a previous run of this script already installed it,
# skip the 10-minute pip install.
for candidate in \
    "$OPEN_WEBUI_VENV/bin/open-webui" \
    /usr/local/bin/open-webui \
    /opt/conda/bin/open-webui \
    /opt/venv/bin/open-webui \
    /opt/sys-venv/bin/open-webui \
    /root/.local/bin/open-webui
do
    if [ -x "$candidate" ]; then
        OPEN_WEBUI_BIN="$candidate"
        log "found existing open-webui at $OPEN_WEBUI_BIN, skipping pip install"
        report_stage '{"stage":"ensure_open_webui","progress_pct":90}'
        break
    fi
done

if [ -z "$OPEN_WEBUI_BIN" ] && command -v open-webui >/dev/null 2>&1; then
    OPEN_WEBUI_BIN="$(command -v open-webui)"
    log "found existing open-webui on PATH at $OPEN_WEBUI_BIN"
    report_stage '{"stage":"ensure_open_webui","progress_pct":90}'
fi

# Module-importable but no console script (rare; could happen if a base
# image used pip's --no-scripts). Start via `python3 -m open_webui`.
if [ -z "$OPEN_WEBUI_BIN" ] && python3 -c 'import open_webui' >/dev/null 2>&1; then
    OPEN_WEBUI_BIN="python3 -m open_webui"
    log "open_webui module importable; using 'python3 -m open_webui'"
    report_stage '{"stage":"ensure_open_webui","progress_pct":90}'
fi

if [ -z "$OPEN_WEBUI_BIN" ]; then
    log "open-webui not preinstalled, installing into $OPEN_WEBUI_VENV (5–15 min)"
    report_stage '{"stage":"ensure_open_webui","progress_pct":5}'

    if ! python3 -m venv "$OPEN_WEBUI_VENV" >> "$INSTALL_LOG" 2>&1; then
        log "python3 venv module missing; installing python3-venv"
        apt-get update >> "$INSTALL_LOG" 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip >> "$INSTALL_LOG" 2>&1
        python3 -m venv "$OPEN_WEBUI_VENV" >> "$INSTALL_LOG" 2>&1
    fi

    report_stage '{"stage":"ensure_open_webui","progress_pct":15}'

    "${OPEN_WEBUI_VENV}/bin/python" -m pip install --upgrade pip >> "$INSTALL_LOG" 2>&1
    report_stage '{"stage":"ensure_open_webui","progress_pct":25}'

    # Tail the install log into our own log too, so SSH debug doesn't
    # have to chase two files. tee runs in background and dies when its
    # input fd is closed (i.e. when pip finishes).
    tail -F "$INSTALL_LOG" 2>/dev/null | sed 's/^/[pip] /' &
    tail_pid=$!

    # Advance the progress bar 35→85% on a fixed timer during the long
    # pip step. The actual pip command finishes whenever it finishes;
    # the ticker just keeps the UI alive. We kill it before reporting 90%
    # so the ticker can't emit a stale 85% AFTER our 90% report.
    (
        for pct in 35 45 55 65 75 85; do
            sleep 60
            report_stage "{\"stage\":\"ensure_open_webui\",\"progress_pct\":${pct}}" || true
        done
    ) &
    ticker_pid=$!

    set +e
    "${OPEN_WEBUI_VENV}/bin/pip" install --no-cache-dir open-webui >> "$INSTALL_LOG" 2>&1
    pip_status=$?
    set -e

    kill "$ticker_pid" 2>/dev/null || true
    wait "$ticker_pid" 2>/dev/null || true
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true

    if [ "$pip_status" -ne 0 ]; then
        log "pip install open-webui failed with exit $pip_status"
        # Last few lines of the install log give the customer something
        # actionable in the wizard's error card. 500-char cap matches
        # comfyui-flux's start_server convention.
        tail_msg="$(tail -c 500 "$INSTALL_LOG" 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g')"
        report_stage "{\"stage\":\"ensure_open_webui\",\"message\":\"pip install open-webui упал. ${tail_msg}\"}"
        exit "$pip_status"
    fi

    OPEN_WEBUI_BIN="${OPEN_WEBUI_VENV}/bin/open-webui"
    report_stage '{"stage":"ensure_open_webui","progress_pct":90}'
fi

# Secret key — generate once and persist so customer's existing chat
# sessions survive a stop/start cycle.
if [ -s "$OPEN_WEBUI_SECRET_FILE" ]; then
    WEBUI_SECRET_KEY="$(cat "$OPEN_WEBUI_SECRET_FILE")"
else
    WEBUI_SECRET_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"
    umask 077
    printf '%s\n' "$WEBUI_SECRET_KEY" > "$OPEN_WEBUI_SECRET_FILE"
fi

if ! port_responds "$OPEN_WEBUI_PORT"; then
    log "starting open-webui serve on :${OPEN_WEBUI_PORT}"
    # OPEN_WEBUI_BIN may be a multi-word command ("python3 -m open_webui"),
    # so we deliberately leave it unquoted. shellcheck-disable.
    # shellcheck disable=SC2086
    OLLAMA_BASE_URL="$OLLAMA_HOST" \
        WEBUI_SECRET_KEY="$WEBUI_SECRET_KEY" \
        nohup $OPEN_WEBUI_BIN serve --host 0.0.0.0 --port "$OPEN_WEBUI_PORT" \
        > /var/log/open-webui.log 2>&1 &
fi

# Sanity wait — we only need to know it can come up. The hard ready-check
# is start_server below, which has the real timeout.
for _ in $(seq 1 30); do
    if port_responds "$OPEN_WEBUI_PORT"; then
        break
    fi
    sleep 1
done

report_stage '{"stage":"ensure_open_webui","progress_pct":100}'
log "ensure_open_webui done: bin=$OPEN_WEBUI_BIN port=$(port_responds "$OPEN_WEBUI_PORT" && echo up || echo not-yet)"

# --- stage 3: download_model ---------------------------------------------

CC_CURRENT_STAGE="download_model"
log "stage: download_model (${OLLAMA_MODEL})"
report_stage "{\"stage\":\"download_model\",\"progress_pct\":0}"

# Skip the pull if the model is already present. `ollama list` outputs
# one line per cached model with the name in the first column; the model
# name may or may not include the tag (`:latest` is implicit). Match both.
already_cached=0
if ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "$OLLAMA_MODEL"; then
    already_cached=1
elif ollama list 2>/dev/null | awk 'NR>1 {print $1}' | grep -Fxq "${OLLAMA_MODEL%:*}:latest" && [ "${OLLAMA_MODEL##*:}" = "latest" ]; then
    already_cached=1
fi

if [ "$already_cached" -eq 1 ]; then
    log "model ${OLLAMA_MODEL} already cached, skipping pull"
    report_stage '{"stage":"download_model","progress_pct":100}'
else
    # `ollama pull <model>` emits progress lines like
    #   pulling 8eeb52dfb3bb... 100% ▕████████████████▏ 4.7 GB
    # for each layer in sequence. The model weights themselves are the
    # one >1 GB layer and dominate the wall-clock; the manifest +
    # config layers are tiny and flash from 0 → 100% in under a second
    # each. We extract the last percentage seen on every line and
    # forward it to /api/agent/provision throttled to mod-10 to avoid
    # hammering the endpoint. The bar may visually reset to 0 between
    # sub-layers — that's expected and lasts a beat.
    last_reported=-1
    set +e
    ollama pull "$OLLAMA_MODEL" 2>&1 | \
    while IFS= read -r line; do
        echo "$line"
        pct=$(echo "$line" | grep -oE '[0-9]+%' | tail -1 | tr -d '%' || true)
        if [ -n "$pct" ] && [ "$pct" -ne "$last_reported" ] 2>/dev/null; then
            mod=$((pct % 10))
            if [ "$mod" -eq 0 ] || [ "$pct" -ge 99 ]; then
                report_stage "{\"stage\":\"download_model\",\"progress_pct\":${pct}}"
                last_reported=$pct
            fi
        fi
    done
    pull_status=${PIPESTATUS[0]}
    set -e

    if [ "$pull_status" -ne 0 ]; then
        log "ollama pull failed with exit $pull_status"
        # `ollama pull` itself prints the real error (e.g. "Error: model not
        # found" or a network failure) to its own stderr, which we already
        # tee'd above. The stage-message field is the short, user-facing
        # version that surfaces in the wizard.
        report_stage "{\"stage\":\"download_model\",\"message\":\"ollama pull завершился с кодом ${pull_status}. См. /var/log/cc-provision.log.\"}"
        exit "$pull_status"
    fi

    report_stage '{"stage":"download_model","progress_pct":100}'
fi

# --- stage 4: start_server -----------------------------------------------
#
# ensure_open_webui already started Open WebUI; here we just wait until
# it's actually answering HTTP, then declare done. Mirrors comfyui-flux's
# start_server contract so the customer-app frontend's provision_marker
# ready-check fires the moment we exit 0.

CC_CURRENT_STAGE="start_server"
log "stage: start_server"
report_stage '{"stage":"start_server"}'

OPEN_WEBUI_BIND_TIMEOUT_S=120
for _ in $(seq 1 "$OPEN_WEBUI_BIND_TIMEOUT_S"); do
    if port_responds "$OPEN_WEBUI_PORT"; then
        report_stage "{\"stage\":\"start_server\",\"progress_pct\":100}"
        log "provisioning complete"
        exit 0
    fi
    sleep 1
done

log "open-webui did not bind port ${OPEN_WEBUI_PORT} within ${OPEN_WEBUI_BIND_TIMEOUT_S}s"
# Surface the last few lines of the crash to the UI so the customer has
# something more useful than "didn't start". The 500-char cap matches
# what comfyui-flux's start_server does — keeps the POST body small and
# fits comfortably in the wizard's error card.
tail_msg="$(tail -c 500 /var/log/open-webui.log 2>/dev/null | tr -d '\r' | tr '\n' ' ' | sed 's/"/'"'"'/g')"
report_stage "{\"stage\":\"start_server\",\"message\":\"Open WebUI не привязался к порту ${OPEN_WEBUI_PORT} за ${OPEN_WEBUI_BIND_TIMEOUT_S}с. ${tail_msg}\"}"
exit 1

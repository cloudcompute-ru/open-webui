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
#   install_runtime    Ollama + Open WebUI reachable on their ports
#   download_model     `ollama pull` of the default model
#   start_server       Open WebUI binds OPEN_WEBUI_PORT and serves HTTP
#
# Anything else is fine to log to stdout but won't drive the UI.
#
# stdout/stderr go to /var/log/cc-provision.log (the onstart wrapper sets
# this up via `nohup ... > /var/log/cc-provision.log 2>&1 &`).

set -euo pipefail

CC_PROVISION_URL="${CC_PROVISION_URL:-}"
CC_AGENT_TOKEN="${CC_AGENT_TOKEN:-}"

# Default model. llama3.1:8b is the v1 pick: ~5 GB on disk, fits in 12 GB
# VRAM, and gives a working chat without a 10-minute wait on first connect.
# Override with `OLLAMA_MODEL=llama3.3:70b bash provision.sh` (etc.) for
# manual testing; the customer app launches us with no override so the
# default applies in production.
OLLAMA_MODEL="${OLLAMA_MODEL:-llama3.1:8b}"
OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
OPEN_WEBUI_PORT="${OPEN_WEBUI_PORT:-7500}"
OPEN_WEBUI_VENV="${OPEN_WEBUI_VENV:-/workspace/cc-open-webui-venv}"

# --- helpers --------------------------------------------------------------

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

# port_responds <port>
#
# True if something is bound on `localhost:<port>` and answering HTTP.
# We use this instead of a raw TCP-bind check because Open WebUI takes
# a few extra seconds after binding the socket before its router is
# ready to actually serve requests, and we want to gate on the latter.
port_responds() {
    curl -fsS --max-time 1 "http://127.0.0.1:${1}/" >/dev/null 2>&1
}

# --- stage 1: install_runtime --------------------------------------------
#
# The `open-webui` Vast.ai template (hash d34be35..., see
# resources/vastai-templates/open-webui.md on the customer-app side)
# ships Ubuntu 22.04 + CUDA 12 + Ollama + Open WebUI 0.8 preinstalled,
# and typically starts both as background services on container boot.
# We defensively re-start whichever isn't reachable yet — covers the
# case where the template image drifted, or someone is running this
# script on a vanilla CUDA image instead of the template.

log "stage: install_runtime"
report_stage '{"stage":"install_runtime"}'

# Ollama daemon. The standard binary location after the upstream installer.
# `ollama serve` starts the HTTP API on :11434 (default OLLAMA_HOST).
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
    # Brief wait so the next stage doesn't race the bind.
    for _ in $(seq 1 20); do
        if curl -fsS --max-time 1 "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
            break
        fi
        sleep 1
    done
fi

if ! curl -fsS --max-time 2 "${OLLAMA_HOST}/api/tags" >/dev/null 2>&1; then
    log "ollama did not become reachable on ${OLLAMA_HOST} within 20s"
    report_stage '{"stage":"install_runtime","message":"Ollama не запустился. См. /var/log/ollama.log."}'
    exit 1
fi

# Open WebUI. The Vast template publishes Open WebUI on :7500 and Jupyter
# on :8080; checking 8080 here waits on the wrong service. If the template
# has not started Open WebUI yet (or this script is running on a plain CUDA
# image), install a known-good executable into our own venv and start that.
# The webui talks to ollama via OLLAMA_BASE_URL env; setting it explicitly
# makes us robust to whatever default the template might or might not bake in.
if ! port_responds "$OPEN_WEBUI_PORT"; then
    OPEN_WEBUI_BIN=""
    if command -v open-webui >/dev/null 2>&1; then
        OPEN_WEBUI_BIN="$(command -v open-webui)"
    elif [ -x "${OPEN_WEBUI_VENV}/bin/open-webui" ]; then
        OPEN_WEBUI_BIN="${OPEN_WEBUI_VENV}/bin/open-webui"
    else
        log "open-webui binary not found; installing into ${OPEN_WEBUI_VENV}"
        mkdir -p "$(dirname "$OPEN_WEBUI_VENV")"
        if ! python3 -m venv "$OPEN_WEBUI_VENV" >> /var/log/open-webui-install.log 2>&1; then
            log "python3 venv module missing; installing python3-venv"
            apt-get update >> /var/log/open-webui-install.log 2>&1
            DEBIAN_FRONTEND=noninteractive apt-get install -y python3-venv python3-pip >> /var/log/open-webui-install.log 2>&1
            python3 -m venv "$OPEN_WEBUI_VENV" >> /var/log/open-webui-install.log 2>&1
        fi
        "${OPEN_WEBUI_VENV}/bin/python" -m pip install --upgrade pip >> /var/log/open-webui-install.log 2>&1
        "${OPEN_WEBUI_VENV}/bin/pip" install --no-cache-dir open-webui >> /var/log/open-webui-install.log 2>&1
        OPEN_WEBUI_BIN="${OPEN_WEBUI_VENV}/bin/open-webui"
    fi

    log "starting ${OPEN_WEBUI_BIN} serve on :${OPEN_WEBUI_PORT}"
    OLLAMA_BASE_URL="$OLLAMA_HOST" \
        nohup "$OPEN_WEBUI_BIN" serve --host 0.0.0.0 --port "$OPEN_WEBUI_PORT" \
        > /var/log/open-webui.log 2>&1 &
fi

# Sanity wait — we only need to know it *can* start. The real ready-check
# happens in stage 3; here we just want a clear failure mode if the binary
# crashes immediately on launch.
for _ in $(seq 1 30); do
    if port_responds "$OPEN_WEBUI_PORT"; then
        break
    fi
    sleep 1
done

log "install_runtime: ollama=ok, open-webui port=$(port_responds "$OPEN_WEBUI_PORT" && echo up || echo not-yet)"

# --- stage 2: download_model ---------------------------------------------

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

# --- stage 3: start_server -----------------------------------------------
#
# Stage 1 already started Open WebUI (or trusted that the template did);
# here we just wait until it's actually answering HTTP, then declare
# done. Mirrors comfyui-flux's start_server contract so the customer-app
# frontend's provision_marker ready-check fires the moment we exit 0.

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

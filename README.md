# open-webui (CloudCompute chatbot runtime)

`provision.sh` for the customer-app **chatbot** application (`/applications/chatbot`).

## Docker image (P1 baked runtime)

The Vast `vastai/openwebui` template does not ship a runnable `open-webui` binary. We bake it into:

`cloudcomputeru/openwebui:v1`

Build locally:

```bash
docker build -t cloudcomputeru/openwebui:v1 .
```

CI pushes on git tags `v*` (requires `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN` repo secrets).

The customer app launches chatbot with `runtime.image` set to that tag (see `config/applications.php` in the main app repo).

## provision.sh

Pinned by SHA in `config/applications.php` → `provisioning.script_sha`. After changing this file, commit, push, and bump the SHA in the customer app.

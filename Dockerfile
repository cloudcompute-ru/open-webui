# CloudCompute chatbot runtime — Open WebUI pre-installed on the Vast
# openwebui CUDA base. Built image: cloudcomputeru/openwebui:v1
FROM vastai/openwebui:v0.8.12

RUN python3 -m venv /opt/cc-open-webui-venv \
    && /opt/cc-open-webui-venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/cc-open-webui-venv/bin/pip install --no-cache-dir open-webui

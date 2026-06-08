#!/usr/bin/env bash
set -Eeuo pipefail

readonly WORKSPACE_DIR="${WORKSPACE:-/workspace}"
readonly APP_DIR="${WORKSPACE_DIR}/VibeVoice"
readonly MODEL_DIR="${WORKSPACE_DIR}/models/VibeVoice-1.5B"
readonly REPO_URL="https://github.com/NeuralFalconYT/VibeVoice.git"
readonly MODEL_ID="microsoft/VibeVoice-1.5B"

echo "===== VibeVoice provisioning starting ====="

mkdir -p "${WORKSPACE_DIR}" "${WORKSPACE_DIR}/models"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ffmpeg libsndfile1
rm -rf /var/lib/apt/lists/*

# Vast's image owns this environment; install application packages into it.
source /venv/main/bin/activate
python -m pip install --upgrade pip setuptools wheel

if [[ ! -d "${APP_DIR}/.git" ]]; then
    git clone --depth 1 "${REPO_URL}" "${APP_DIR}"
fi

python -m pip install -e "${APP_DIR}"
python -m pip install --upgrade huggingface_hub gradio

if [[ ! -f "${MODEL_DIR}/model.safetensors.index.json" ]]; then
    hf download "${MODEL_ID}" --local-dir "${MODEL_DIR}"
fi

mkdir -p "${APP_DIR}/demo/voices" "${WORKSPACE_DIR}/logs"

cat > /opt/supervisor-scripts/vibevoice.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source /venv/main/bin/activate
cd "${WORKSPACE:-/workspace}/VibeVoice"

# The Portal proxies external port 7860 to local port 17860.
export GRADIO_SERVER_NAME=127.0.0.1
export GRADIO_SERVER_PORT=17860

exec python demo/gradio_demo.py \
    --model_path "${WORKSPACE:-/workspace}/models/VibeVoice-1.5B" \
    --inference_steps 22
EOF
chmod +x /opt/supervisor-scripts/vibevoice.sh

cat > /etc/supervisor/conf.d/vibevoice.conf <<'EOF'
[program:vibevoice]
environment=PROC_NAME="%(program_name)s"
command=/opt/supervisor-scripts/vibevoice.sh
autostart=false
autorestart=true
startsecs=10
stopasgroup=true
killasgroup=true
stdout_logfile=/dev/stdout
stdout_logfile_maxbytes=0
redirect_stderr=true
EOF

supervisorctl reread
supervisorctl update

cat > "${WORKSPACE_DIR}/VIBEVOICE_READY.txt" <<EOF
VibeVoice provisioning completed.

Voice files:
${APP_DIR}/demo/voices/

Model:
${MODEL_DIR}

Service:
supervisorctl status vibevoice

After uploading voice files, start it with:
supervisorctl start vibevoice
EOF

echo "===== VibeVoice provisioning complete ====="
echo "Upload voices to ${APP_DIR}/demo/voices/"
echo "Then run: supervisorctl start vibevoice"

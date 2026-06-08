#!/usr/bin/env bash
set -Eeuo pipefail

readonly WORKSPACE_DIR="${WORKSPACE:-/workspace}"
readonly APP_DIR="${WORKSPACE_DIR}/VibeVoice"
readonly MODEL_DIR="${WORKSPACE_DIR}/models/VibeVoice-1.5B"
readonly REPO_URL="https://github.com/NeuralFalconYT/VibeVoice.git"
readonly MODEL_ID="microsoft/VibeVoice-1.5B"
readonly VOICES_REPO_URL="${VOICES_REPO_URL:-https://github.com/getspastic/VibeVoiceProvisioning.git}"
readonly VOICES_REPO_REF="${VOICES_REPO_REF:-main}"

echo "===== VibeVoice provisioning starting ====="

mkdir -p "${WORKSPACE_DIR}" "${WORKSPACE_DIR}/models"

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ffmpeg libsndfile1 git-lfs
rm -rf /var/lib/apt/lists/*

# Vast's image owns this environment; install application packages into it.
source /venv/main/bin/activate
python -m pip install --upgrade pip setuptools wheel

if [[ ! -d "${APP_DIR}/.git" ]]; then
    git clone --depth 1 "${REPO_URL}" "${APP_DIR}"
fi

python -m pip install -e "${APP_DIR}"
# hf-gradio is a base-image helper with constraints that conflict with Gradio 5.
python -m pip uninstall -y hf-gradio || true

# Resolve these together so Gradio cannot upgrade huggingface-hub to 1.x.
python -m pip install --upgrade --force-reinstall \
    "huggingface_hub>=0.30,<1.0" \
    "gradio>=5,<6"

python - <<PY
from pathlib import Path

demo = Path("${APP_DIR}/demo/gradio_demo.py")
text = demo.read_text()

replacements = {
    "min_yield_interval = 15 # Yield every 15 seconds":
        "min_yield_interval = 3 # Yield at least every 3 seconds",
    "min_chunk_size = sample_rate * 30 # At least 2 seconds of audio":
        "min_chunk_size = sample_rate * 2 # Start playback after 2 seconds of audio",
}

for old, new in replacements.items():
    if old in text:
        text = text.replace(old, new, 1)
    elif new not in text:
        raise SystemExit(f"Expected streaming setting not found: {old}")

demo.write_text(text)
print("Patched VibeVoice streaming buffer: 2-second chunks, 3-second interval")
PY

if [[ ! -f "${MODEL_DIR}/model.safetensors.index.json" ]]; then
    hf download "${MODEL_ID}" --local-dir "${MODEL_DIR}"
fi

mkdir -p "${APP_DIR}/demo/voices" "${WORKSPACE_DIR}/logs"

VOICES_CHECKOUT="$(mktemp -d)"
git clone --depth 1 --branch "${VOICES_REPO_REF}" \
    "${VOICES_REPO_URL}" "${VOICES_CHECKOUT}"
git -C "${VOICES_CHECKOUT}" lfs pull

if [[ -d "${VOICES_CHECKOUT}/voices" ]]; then
    find "${VOICES_CHECKOUT}/voices" -maxdepth 1 -type f \
        \( -iname '*.wav' -o -iname '*.mp3' -o -iname '*.flac' -o -iname '*.ogg' \) \
        -exec cp -f {} "${APP_DIR}/demo/voices/" \;
fi

VOICE_COUNT="$(find "${APP_DIR}/demo/voices" -maxdepth 1 -type f \
    \( -iname '*.wav' -o -iname '*.mp3' -o -iname '*.flac' -o -iname '*.ogg' \) \
    | wc -l)"

rm -rf "${VOICES_CHECKOUT}"
echo "Installed ${VOICE_COUNT} custom voice files"

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
autostart=true
autorestart=true
startsecs=10
stopasgroup=true
killasgroup=true
stdout_logfile=/workspace/logs/vibevoice.log
stdout_logfile_maxbytes=50MB
stdout_logfile_backups=2
redirect_stderr=true
EOF

supervisorctl reread
supervisorctl update

python - <<'PY'
import gradio
import huggingface_hub
import torch

assert gradio.__version__.split(".", 1)[0] == "5", gradio.__version__
assert int(huggingface_hub.__version__.split(".", 1)[0]) < 1, huggingface_hub.__version__
assert torch.cuda.is_available(), "CUDA is not available to PyTorch"

print("Dependency check passed")
print("PyTorch:", torch.__version__)
print("CUDA:", torch.version.cuda)
print("GPU:", torch.cuda.get_device_name())
print("Gradio:", gradio.__version__)
print("huggingface_hub:", huggingface_hub.__version__)
PY

cat > "${WORKSPACE_DIR}/VIBEVOICE_READY.txt" <<EOF
VibeVoice provisioning completed.

Voice files:
${APP_DIR}/demo/voices/

Model:
${MODEL_DIR}

Service:
supervisorctl status vibevoice

VibeVoice starts automatically after provisioning.

Watch generation progress:
tail -F ${WORKSPACE_DIR}/logs/vibevoice.log

Local app URL:
http://127.0.0.1:17860
EOF

echo "===== VibeVoice provisioning complete ====="
echo "Installed ${VOICE_COUNT} custom voices in ${APP_DIR}/demo/voices/"
echo "VibeVoice starts automatically."

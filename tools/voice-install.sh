#!/bin/bash
# Installs the voice assistant (navplotter/voice.py) for the desktop user of this computer (a PC with Ubuntu, or a
# Raspberry Pi), the one whose audio (PipeWire) has the Bluetooth headset or the speakerphone. Run it as that user,
# not with sudo:
#   bash /opt/navplotter/tools/voice-install.sh            speech to text and voice
#   NAVPLOTTER_LLM=1 bash /opt/navplotter/tools/voice-install.sh     also the local language model
# Choices (environment variables), the defaults depending on the computer:
#   NAVPLOTTER_WHISPER=large-v3-turbo|medium|small|base|tiny   speech recognition model
#       PC: large-v3-turbo (quantized, 550 MB: much better in Italian, fast on a PC); Raspberry Pi: small (466 MB)
#   NAVPLOTTER_LLM_MODEL=1.5b|3b|7b       language model
#       PC with 12 GB of RAM or more: 7b (4.7 GB, the best answers); other PCs: 3b (2 GB); Raspberry Pi: 1.5b (1.1 GB)
#   NAVPLOTTER_GPU=auto|cuda|vulkan|none  build whisper.cpp and llama.cpp for the graphics card
#       auto: cuda with an NVIDIA card (nvidia-smi works), otherwise none (CPU). vulkan: AMD or Intel cards.
# Everything goes in ~/.local/share/navplotter-voice; downloads that stop are resumed by running it again.
# Running it again with other choices changes models and build (the models already downloaded stay, to compare).
set -euo pipefail

if [ "$(id -u)" = 0 ]; then echo "Run it as the desktop user, without sudo (it asks for sudo only for the packages)"; exit 1; fi
H="$HOME/.local/share/navplotter-voice"
CODE=/opt/navplotter
ARCH=$(uname -m)
RAM_GB=$(awk '/MemTotal/ {print int($2 / 1048576 + 0.5)}' /proc/meminfo)
JOBS=$(nproc)
if [ "$ARCH" = x86_64 ]; then
  WHISPER=${NAVPLOTTER_WHISPER:-large-v3-turbo}
  if [ "$RAM_GB" -ge 12 ]; then LLM_MODEL=${NAVPLOTTER_LLM_MODEL:-7b}; else LLM_MODEL=${NAVPLOTTER_LLM_MODEL:-3b}; fi
  PIPER_ARCH=x86_64
else
  WHISPER=${NAVPLOTTER_WHISPER:-small}
  LLM_MODEL=${NAVPLOTTER_LLM_MODEL:-1.5b}
  PIPER_ARCH=aarch64
fi
GPU=${NAVPLOTTER_GPU:-auto}
if [ "$GPU" = auto ]; then
  if command -v nvidia-smi >/dev/null && nvidia-smi >/dev/null 2>&1; then GPU=cuda; else GPU=none; fi
fi
case "$GPU" in
  cuda)   GGML="-DGGML_CUDA=ON -DGGML_VULKAN=OFF" ;;
  vulkan) GGML="-DGGML_CUDA=OFF -DGGML_VULKAN=ON" ;;
  *)      GPU=none; GGML="-DGGML_CUDA=OFF -DGGML_VULKAN=OFF" ;;
esac
# large-v3-turbo comes quantized (q5_0): a third of the size, the same recognition
[ "$WHISPER" = large-v3-turbo ] && WFILE=ggml-large-v3-turbo-q5_0.bin || WFILE=ggml-$WHISPER.bin
echo "Computer: $ARCH, $(nproc) cores, ${RAM_GB} GB of RAM, GPU: $GPU. Speech recognition: $WHISPER"
mkdir -p "$H/models" "$H/voices" "$H/llm"

get() {   # url file: download, resuming a partial file
  echo "   $(basename "$2")"
  curl -fL --retry 5 -C - -o "$2.part" "$1" && mv "$2.part" "$2"
}

echo "== Packages"
sudo apt-get update -qq
sudo apt-get install -y -qq git cmake build-essential curl pipewire-bin pulseaudio-utils >/dev/null
if [ "$GPU" = cuda ] && ! command -v nvcc >/dev/null; then
  echo "   CUDA toolkit (for the NVIDIA card; a few GB)"
  sudo apt-get install -y -qq nvidia-cuda-toolkit >/dev/null
fi
[ "$GPU" = vulkan ] && sudo apt-get install -y -qq libvulkan-dev glslc >/dev/null

echo "== Speech to text: whisper.cpp (a few minutes to build)"
if [ ! -d "$H/whisper.cpp" ]; then
  git clone -q --depth 1 --branch v1.7.6 https://github.com/ggml-org/whisper.cpp.git "$H/whisper.cpp"
fi
# shellcheck disable=SC2086
cmake -S "$H/whisper.cpp" -B "$H/whisper.cpp/build" -DCMAKE_BUILD_TYPE=Release $GGML >/dev/null
cmake --build "$H/whisper.cpp/build" -j"$JOBS" --target whisper-server >/dev/null
[ -f "$H/models/$WFILE" ] || get "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WFILE" "$H/models/$WFILE"
echo "$WFILE" > "$H/models/use"     # the one to use, also when a better one is there: to compare them

echo "== Voice: Piper, Italian voice Paola"
if [ ! -x "$H/piper/piper" ]; then
  get "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_$PIPER_ARCH.tar.gz" "$H/piper.tar.gz"
  tar -xzf "$H/piper.tar.gz" -C "$H" && rm "$H/piper.tar.gz"
fi
V=https://huggingface.co/rhasspy/piper-voices/resolve/main/it/it_IT/paola/medium/it_IT-paola-medium.onnx
[ -f "$H/voices/it_IT-paola-medium.onnx" ] || get "$V" "$H/voices/it_IT-paola-medium.onnx"
[ -f "$H/voices/it_IT-paola-medium.onnx.json" ] || get "$V.json" "$H/voices/it_IT-paola-medium.onnx.json"

if [ "${NAVPLOTTER_LLM:-0}" = 1 ]; then
  echo "== Language model: llama.cpp (about ten minutes to build)"
  if [ ! -d "$H/llama.cpp" ]; then
    git clone -q --depth 1 https://github.com/ggml-org/llama.cpp.git "$H/llama.cpp"
  fi
  # shellcheck disable=SC2086
  cmake -S "$H/llama.cpp" -B "$H/llama.cpp/build" -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=OFF $GGML >/dev/null
  cmake --build "$H/llama.cpp/build" -j"$JOBS" --target llama-server >/dev/null
  case "$LLM_MODEL" in
    7b) M=bartowski/Qwen2.5-7B-Instruct-GGUF; F=Qwen2.5-7B-Instruct-Q4_K_M.gguf ;;   # Qwen's own is in two parts
    3b) M=Qwen/Qwen2.5-3B-Instruct-GGUF; F=qwen2.5-3b-instruct-q4_k_m.gguf ;;
    *)  M=Qwen/Qwen2.5-1.5B-Instruct-GGUF; F=qwen2.5-1.5b-instruct-q4_k_m.gguf ;;
  esac
  echo "   language model $LLM_MODEL"
  [ -f "$H/llm/$F" ] || { rm -f "$H"/llm/*.gguf; get "https://huggingface.co/$M/resolve/main/$F" "$H/llm/$F"; }
fi

echo "$GPU" > "$H/gpu"     # navplotter.voice then puts the language model on the GPU

echo "== Service navplotter-voice (of this user, started at boot)"
mkdir -p "$HOME/.config/systemd/user"
cat > "$HOME/.config/systemd/user/navplotter-voice.service" <<UNIT
[Unit]
Description=NavPlotter voice assistant (whisper.cpp, Piper, local language model)
After=pipewire.service wireplumber.service

[Service]
WorkingDirectory=$CODE
ExecStart=/usr/bin/python3 -m navplotter.voice
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
sudo loginctl enable-linger "$USER"
systemctl --user daemon-reload
systemctl --user enable -q navplotter-voice
systemctl --user restart navplotter-voice

echo
echo "Done. In the web app, the microphone button at the bottom right: tap, speak, tap again."
echo "Log, with the latency of each answer: journalctl --user -u navplotter-voice -f"
echo "  (on Raspberry Pi OS: sudo journalctl _SYSTEMD_USER_UNIT=navplotter-voice.service -f)"

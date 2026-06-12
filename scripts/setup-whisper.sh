#!/usr/bin/env bash
# Builds whisper.cpp and downloads a ggml model.
#
# NOTE ON NETWORK USE: this one-time, user-initiated setup step is the only
# network access in the project besides AWS Bedrock at runtime. It talks to
# github.com (clone whisper.cpp) and huggingface.co (model download).
#
# Overrides:
#   TTO_WHISPER_DIR    install location (default ~/.local/share/teams-to-obsidian/whisper.cpp)
#   TTO_WHISPER_MODEL  ggml model name  (default large-v3-turbo-q5_0; e.g. small.en for low RAM)
set -euo pipefail

WHISPER_DIR="${TTO_WHISPER_DIR:-$HOME/.local/share/teams-to-obsidian/whisper.cpp}"
MODEL="${TTO_WHISPER_MODEL:-large-v3-turbo-q5_0}"

for tool in git cmake; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "error: $tool is required (xcode-select --install, then 'brew install cmake' if needed)" >&2
    exit 1
  fi
done

if [[ -d "$WHISPER_DIR/.git" ]]; then
  echo "==> whisper.cpp already cloned at $WHISPER_DIR (delete it to re-clone)"
else
  mkdir -p "$(dirname "$WHISPER_DIR")"
  echo "==> Cloning whisper.cpp"
  git clone --depth 1 https://github.com/ggml-org/whisper.cpp "$WHISPER_DIR"
fi

cd "$WHISPER_DIR"
echo "==> Building whisper-cli (Metal acceleration is on by default on Apple Silicon)"
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j --config Release

MODEL_FILE="$WHISPER_DIR/models/ggml-$MODEL.bin"
if [[ -f "$MODEL_FILE" ]]; then
  echo "==> Model already downloaded: $MODEL_FILE"
else
  echo "==> Downloading ggml model: $MODEL"
  ./models/download-ggml-model.sh "$MODEL"
fi

CLI="$WHISPER_DIR/build/bin/whisper-cli"
echo
echo "Done."
echo "  whisper-cli: $CLI"
echo "  model:       $MODEL_FILE"
echo
echo "These match the config defaults unless you overrode TTO_WHISPER_DIR or"
echo "TTO_WHISPER_MODEL — in that case update ~/.config/teams-to-obsidian/config.json:"
cat <<EOF
  "whisper": {
    "cliPath": "$CLI",
    "modelPath": "$MODEL_FILE"
  }
EOF

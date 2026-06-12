#!/usr/bin/env bash
# Downloads sherpa-onnx (prebuilt macOS binaries) and the speaker-diarization
# models, enabling per-speaker labels ("Speaker 1/2/3") in transcripts.
#
# NOTE ON NETWORK USE: like setup-whisper.sh, this is a one-time, user-initiated
# setup step — github.com only. Nothing here runs at meeting time except the
# local binary.
#
# Overrides:
#   TTO_SHERPA_DIR      install location (default ~/.local/share/teams-to-obsidian/sherpa-onnx)
#   TTO_SHERPA_VERSION  sherpa-onnx version tag, e.g. v1.12.0 (default: latest release)
#   TTO_EMBEDDING_URL   speaker-embedding model URL (default: NeMo titanet small, English)
set -euo pipefail

SHERPA_DIR="${TTO_SHERPA_DIR:-$HOME/.local/share/teams-to-obsidian/sherpa-onnx}"
EMBEDDING_URL="${TTO_EMBEDDING_URL:-https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/nemo_en_titanet_small.onnx}"

for tool in curl tar; do
  command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool is required" >&2; exit 1; }
done

mkdir -p "$SHERPA_DIR"
cd "$SHERPA_DIR"

# 1. Prebuilt sherpa-onnx binaries (bin/ + lib/, universal2).
if [[ -x "$SHERPA_DIR/bin/sherpa-onnx-offline-speaker-diarization" ]]; then
  echo "==> sherpa-onnx binaries already present"
else
  VERSION="${TTO_SHERPA_VERSION:-}"
  if [[ -z "$VERSION" ]]; then
    echo "==> Looking up the latest sherpa-onnx release"
    VERSION="$(curl -fsSL https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/latest \
      | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)"
    [[ -n "$VERSION" ]] || { echo "error: could not determine the latest release; set TTO_SHERPA_VERSION" >&2; exit 1; }
  fi
  TARBALL="sherpa-onnx-${VERSION#v}-osx-universal2-shared.tar.bz2"
  echo "==> Downloading $TARBALL"
  curl -fL -o "$TARBALL" \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/$VERSION/$TARBALL"
  tar xjf "$TARBALL" --strip-components=1
  rm -f "$TARBALL"
  [[ -x "$SHERPA_DIR/bin/sherpa-onnx-offline-speaker-diarization" ]] \
    || { echo "error: diarization binary missing after extract — check the release layout" >&2; exit 1; }
fi

# 2. Pyannote segmentation model.
if [[ -f "$SHERPA_DIR/sherpa-onnx-pyannote-segmentation-3-0/model.onnx" ]]; then
  echo "==> Segmentation model already present"
else
  echo "==> Downloading pyannote segmentation model"
  curl -fL -o segmentation.tar.bz2 \
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
  tar xjf segmentation.tar.bz2
  rm -f segmentation.tar.bz2
fi

# 3. Speaker embedding model (English; the release tag's typo is upstream's).
EMBEDDING_FILE="$SHERPA_DIR/$(basename "$EMBEDDING_URL")"
if [[ -f "$EMBEDDING_FILE" ]]; then
  echo "==> Embedding model already present"
else
  echo "==> Downloading speaker embedding model"
  curl -fL -o "$EMBEDDING_FILE" "$EMBEDDING_URL"
fi

echo
echo "Done. Enable diarization in ~/.config/teams-to-obsidian/config.json:"
cat <<EOF
  "diarization": {
    "enabled": true,
    "binaryPath": "$SHERPA_DIR/bin/sherpa-onnx-offline-speaker-diarization",
    "segmentationModelPath": "$SHERPA_DIR/sherpa-onnx-pyannote-segmentation-3-0/model.onnx",
    "embeddingModelPath": "$EMBEDDING_FILE"
  }
EOF

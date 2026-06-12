#!/usr/bin/env bash
# End-to-end pipeline test: spoken WAVs (say) → `process` subcommand → REAL
# whisper.cpp transcription → stub Ollama summarizer → assertions on the
# written Obsidian note. Runs on GitHub macOS runners and locally on a Mac:
#
#   make build
#   TTO_WHISPER_MODEL=tiny.en scripts/setup-whisper.sh
#   scripts/ci/e2e-pipeline-test.sh
#
# What it cannot cover (TCC permissions / audio devices don't exist on hosted
# runners): mic + process-tap capture, meeting detection. See the README.
set -euo pipefail
cd "$(dirname "$0")/../.."

BINARY="${TTO_BINARY:-.build/release/teams-to-obsidian}"
WHISPER_DIR="${TTO_WHISPER_DIR:-$HOME/.local/share/teams-to-obsidian/whisper.cpp}"
MODEL="${TTO_WHISPER_MODEL:-tiny.en}"
STUB_PORT="${TTO_STUB_PORT:-11434}"
WORK="$(mktemp -d)"
STUB_PID=""

cleanup() {
  if [[ -n "$STUB_PID" ]]; then kill "$STUB_PID" 2>/dev/null || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

[[ -x "$BINARY" ]] || { echo "error: $BINARY missing — run 'make build' first" >&2; exit 1; }
[[ -f "$WHISPER_DIR/models/ggml-$MODEL.bin" ]] \
  || { echo "error: whisper model missing — run TTO_WHISPER_MODEL=$MODEL scripts/setup-whisper.sh" >&2; exit 1; }

echo "==> Generating spoken test audio"
say -o "$WORK/me.aiff" "This is the local user speaking. As an action item, I will send the budget report to finance on Friday."
say -o "$WORK/them.aiff" "Thanks for the update. We have decided to ship version two of the project next month."
afconvert "$WORK/me.aiff" -o "$WORK/me.wav" -d LEI16@16000 -c 1 -f WAVE
afconvert "$WORK/them.aiff" -o "$WORK/them.wav" -d LEI16@16000 -c 1 -f WAVE

echo "==> Starting stub Ollama on port $STUB_PORT"
python3 scripts/ci/mock-ollama.py "$STUB_PORT" &
STUB_PID=$!
for _ in $(seq 1 40); do
  if curl -s -o /dev/null -X POST "http://127.0.0.1:$STUB_PORT/api/chat" -d '{}'; then
    break
  fi
  sleep 0.25
done

VAULT="$WORK/vault"
mkdir -p "$VAULT"
CONFIG="$WORK/config.json"
cat > "$CONFIG" <<EOF
{
  "vault": { "path": "$VAULT", "notesFolder": "Meetings", "taskTag": "#task" },
  "whisper": {
    "cliPath": "$WHISPER_DIR/build/bin/whisper-cli",
    "modelPath": "$WHISPER_DIR/models/ggml-$MODEL.bin"
  },
  "summarizer": {
    "backend": "ollama",
    "ollama": { "baseURL": "http://127.0.0.1:$STUB_PORT", "model": "stub" }
  },
  "recording": { "directory": "$WORK/recordings" }
}
EOF

echo "==> test-summarizer against the stub"
"$BINARY" test-summarizer --backend ollama --config "$CONFIG" | tee "$WORK/ts.out"
grep -q "OK" "$WORK/ts.out"

echo "==> Running the pipeline (process)"
"$BINARY" process --mic "$WORK/me.wav" --system "$WORK/them.wav" --config "$CONFIG"

echo "==> Asserting on the note"
shopt -s nullglob
notes=("$VAULT/Meetings/"*.md)
[[ ${#notes[@]} -eq 1 ]] || { echo "expected exactly 1 note, found ${#notes[@]}" >&2; exit 1; }
NOTE="${notes[0]}"
echo "--- $NOTE"
cat "$NOTE"
echo "---"

fail=0
check() {
  grep -qF -- "$1" "$NOTE" || { echo "MISSING from note: $1" >&2; fail=1; }
}
check 'title: "CI Test Meeting"'
check 'type: meeting'
check '## Summary'
check 'This is a canned summary'
check '- [ ] Me: send the budget report to finance #task'
check '## Decisions'
check '**Me**'
check '**Them**'
case "$(basename "$NOTE")" in
  *"CI Test Meeting"*) ;;
  *) echo "filename does not carry the title: $(basename "$NOTE")" >&2; fail=1 ;;
esac
[[ $fail -eq 0 ]] || exit 1

echo "==> E2E pipeline test passed"

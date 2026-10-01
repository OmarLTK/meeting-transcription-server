#!/bin/bash
# Launch native Ollama with the environment Speakr depends on, then preload the model.
#
# Why this exists: the Ollama macOS app only sees variables set with
# `launchctl setenv`, and those do not survive a reboot. If Ollama starts
# without OLLAMA_CONTEXT_LENGTH it falls back to a small default context and
# silently truncates long transcripts — summaries look fine but ignore the end
# of the meeting. Run this at login via launchd/local.speakr.ollama.plist and
# remove Ollama from System Settings > General > Login Items so it can't race.
set -euo pipefail

OLLAMA_MODEL="${OLLAMA_MODEL:-gpt-oss:20b}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-32768}"
KEEP_ALIVE="${KEEP_ALIVE:-24h}"
API="http://127.0.0.1:11434"

log() { echo "[$(date '+%F %T')] $*"; }

launchctl setenv OLLAMA_CONTEXT_LENGTH "$CONTEXT_LENGTH"
launchctl setenv OLLAMA_KEEP_ALIVE "$KEEP_ALIVE"
log "Set OLLAMA_CONTEXT_LENGTH=$CONTEXT_LENGTH OLLAMA_KEEP_ALIVE=$KEEP_ALIVE"

# Restart Ollama so the running process inherits the variables.
osascript -e 'quit app "Ollama"' >/dev/null 2>&1 || true
sleep 3
open -a Ollama
log "Launched Ollama"

for _ in $(seq 1 30); do
  if curl -fsS "$API/api/version" >/dev/null 2>&1; then break; fi
  sleep 2
done
curl -fsS "$API/api/version" >/dev/null || { log "ERROR: Ollama API not responding"; exit 1; }

# A generate request with no prompt loads the model into memory.
curl -fsS "$API/api/generate" \
  -d "{\"model\":\"$OLLAMA_MODEL\",\"keep_alive\":\"$KEEP_ALIVE\"}" >/dev/null
log "Preloaded $OLLAMA_MODEL"

ollama ps || true

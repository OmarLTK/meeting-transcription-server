#!/bin/bash
# Read-only health check for the whole stack. Exits 1 if anything critical fails.
# Usage: SPEAKR_DIR=~/speakr ./scripts/healthcheck.sh
set -uo pipefail

SPEAKR_DIR="${SPEAKR_DIR:-$HOME/speakr}"
OLLAMA_MODEL="${OLLAMA_MODEL:-gpt-oss:20b}"
EXPECTED_CTX="${EXPECTED_CTX:-32768}"
MIN_FREE_GB="${MIN_FREE_GB:-30}"

fail=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; fail=1; }

echo "== Container runtime"
if colima status >/dev/null 2>&1; then ok "Colima running"; else bad "Colima not running (brew services start colima)"; fi

state="$(docker inspect -f '{{.State.Status}}' speakr 2>/dev/null || echo missing)"
if [ "$state" = "running" ]; then ok "speakr container running"; else bad "speakr container: $state"; fi

binding="$(docker port speakr 8899 2>/dev/null | tr '\n' ' ')"
if [ -z "$binding" ]; then
  bad "port 8899 not published"
elif echo "$binding" | tr ' ' '\n' | grep -v '^$' | grep -qv '^127\.0\.0\.1:'; then
  bad "port 8899 bound beyond loopback ($binding) — LAN can bypass HTTPS"
else
  ok "port 8899 bound to loopback only"
fi

code="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8899/ || true)"
case "$code" in 200|302) ok "Speakr HTTP $code";; *) bad "Speakr HTTP ${code:-none}";; esac

echo "== Speakr config (live container env)"
envget() { docker exec speakr printenv "$1" 2>/dev/null || true; }
if [ "$(envget ENABLE_AUTO_DELETION)" = "true" ]; then ok "auto-deletion enabled"; else warn "auto-deletion not enabled"; fi
dm="$(envget DELETION_MODE)"
if [ "$dm" = "audio_only" ]; then ok "DELETION_MODE=audio_only"
elif [ -n "$dm" ]; then bad "DELETION_MODE=$dm (would delete transcripts)"
else warn "DELETION_MODE unset"; fi
rd="$(envget GLOBAL_RETENTION_DAYS)"; [ -n "$rd" ] && ok "retention days: $rd"
if [ "$(envget ENABLE_PUBLIC_SHARING)" = "false" ]; then ok "public sharing off"; else warn "public sharing is ON"; fi
if [ "$(envget ALLOW_REGISTRATION)" = "false" ]; then ok "open registration off"; else bad "open registration is ON"; fi
[ -n "$(envget PRESERVE_TEMP_AUDIO)" ] && warn "PRESERVE_TEMP_AUDIO is set (keeps untracked audio)"

echo "== Ollama"
if curl -fsS http://127.0.0.1:11434/api/version >/dev/null 2>&1; then ok "Ollama API up on host"; else bad "Ollama API down"; fi

if docker exec speakr python3 -c "import urllib.request;urllib.request.urlopen('http://host.docker.internal:11434/api/version',timeout=5)" >/dev/null 2>&1; then
  ok "container can reach Ollama"
else
  bad "container cannot reach host.docker.internal:11434"
fi

ctx_env="$(launchctl getenv OLLAMA_CONTEXT_LENGTH 2>/dev/null || true)"
if [ "$ctx_env" = "$EXPECTED_CTX" ]; then ok "OLLAMA_CONTEXT_LENGTH=$ctx_env"
else bad "OLLAMA_CONTEXT_LENGTH='$ctx_env' (expected $EXPECTED_CTX) — run scripts/start-ollama.sh"; fi

ps_out="$(ollama ps 2>/dev/null || true)"
if echo "$ps_out" | grep -q "$OLLAMA_MODEL"; then
  if echo "$ps_out" | grep "$OLLAMA_MODEL" | grep -q "$EXPECTED_CTX"; then
    ok "$OLLAMA_MODEL loaded at context $EXPECTED_CTX"
  else
    warn "$OLLAMA_MODEL loaded but context $EXPECTED_CTX not shown — check 'ollama ps' manually"
  fi
else
  warn "$OLLAMA_MODEL not resident (first summary will be slow)"
fi

echo "== Disk"
free_gb="$(df -g "$SPEAKR_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
if [ "${free_gb:-0}" -ge "$MIN_FREE_GB" ]; then ok "${free_gb} GB free"; else warn "only ${free_gb:-?} GB free"; fi
[ -d "$SPEAKR_DIR/uploads" ] && ok "uploads/ = $(du -sh "$SPEAKR_DIR/uploads" 2>/dev/null | cut -f1)"

echo "== Tailscale"
if command -v tailscale >/dev/null 2>&1; then
  serve="$(tailscale serve status 2>/dev/null || true)"
  if [ -z "$serve" ] || echo "$serve" | grep -qi "no serve config"; then
    bad "no Tailscale Serve config (colleagues cannot reach HTTPS)"
  else
    ok "Tailscale Serve configured"
    echo "$serve" | grep -qi "funnel on" && warn "Funnel is ON: Speakr is reachable from the public internet"
  fi
else
  warn "tailscale CLI not on PATH"
fi

echo
if [ "$fail" -eq 0 ]; then echo "All critical checks passed."; else echo "One or more critical checks FAILED."; fi
exit "$fail"

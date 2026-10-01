# Runbook

Assumes an Apple Silicon Mac with Homebrew, an admin account, and this repo cloned to `~/meeting-transcription-server`. Speakr's runtime directory is `~/speakr`. Adjust paths if yours differ.

---

## 1. Install

### 1.1 Container runtime (Colima)

```bash
brew install colima docker docker-compose
mkdir -p ~/.docker
# Let the docker CLI find the Homebrew compose plugin (skip if config.json already has this)
cat > ~/.docker/config.json << 'JSON'
{ "cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"] }
JSON
colima start --cpu 4 --memory 8
brew services start colima       # start at login
docker compose version           # must print a version
```

### 1.2 Ollama (native)

```bash
brew install --cask ollama
ollama pull gpt-oss:20b
```

Install the launchd agent so Ollama always starts with the right context length:

```bash
sed "s#__REPO__#$HOME/meeting-transcription-server#g" \
  ~/meeting-transcription-server/launchd/local.speakr.ollama.plist \
  > ~/Library/LaunchAgents/local.speakr.ollama.plist
launchctl load ~/Library/LaunchAgents/local.speakr.ollama.plist
```

Then in **System Settings → General → Login Items**, remove Ollama so it doesn't start on its own before the agent sets the variables. Check the log at `/tmp/speakr-ollama.log`.

### 1.3 Speakr

```bash
mkdir -p ~/speakr && cd ~/speakr
cp ~/meeting-transcription-server/docker-compose.yml .
cp ~/meeting-transcription-server/.env.example .env
chmod 600 .env
nano .env        # set TRANSCRIPTION_API_KEY, ADMIN_PASSWORD, ADMIN_EMAIL
docker compose up -d
docker compose logs -f app     # Ctrl+C once it is listening on 8899 without errors
```

Log in at `http://localhost:8899` and change the admin password.

### 1.4 HTTPS via Tailscale

```bash
brew install tailscale     # or the Mac App Store app; use one, not both
sudo tailscale up
tailscale serve --bg 8899
tailscale serve status     # shows the https://<host>.<tailnet>.ts.net URL
```

Do **not** run `tailscale funnel`. See ADR-005.

---

## 2. Unattended operation

```bash
sudo pmset -a sleep 0 disablesleep 1   # never sleep
sudo pmset -a autorestart 1            # boot after power failure
sudo pmset -a womp 1                   # wake on network access
```

System Settings: enable **Remote Login** (SSH) and **Screen Sharing**. Decide the FileVault question with the system owner (ADR-007). Automatic login is only available with FileVault off.

**Test it for real:** `sudo reboot`, walk away, and five minutes later load the `.ts.net` URL from another machine, then run the health check.

---

## 3. Verify

```bash
SPEAKR_DIR=~/speakr ~/meeting-transcription-server/scripts/healthcheck.sh
```

Every `FAIL` needs fixing before the team uses the system.

**Context length (manual check).** `ollama ps` shows a `CONTEXT` column on current versions. It must read `32768`. If it reads anything smaller, the running Ollama predates the variable: run `scripts/start-ollama.sh`.

**Truncation test (behavioural).** Record or upload a meeting of 30+ minutes. Open its chat and ask about something said only in the **final three minutes**. If the model can't answer, the transcript is being truncated somewhere, whatever the counters say. The admin **Token Usage** page breaks out prompt vs. completion tokens; a 30-minute meeting should show several thousand prompt tokens.

**Transcription completeness.** Compare the transcript's last timestamp and word count with the recording length. A 30-minute conversation is typically 3,000–5,000 words.

---

## 4. Retention (10 days, audio only)

Order matters. The first sweep strips audio from **every** recording already older than 10 days, permanently.

1. **Account Settings → Tags → Create Tag**: `Keep Audio`, tick **Protect from Auto-Deletion**. Apply it to any existing recording whose audio must survive.
2. Back up (section 5).
3. Confirm `.env` has exactly one of each, with no duplicates:
   ```bash
   grep -E "AUTO_DELETION|RETENTION_DAYS|DELETION_MODE|PRESERVE_TEMP" .env
   ```
   Expect `ENABLE_AUTO_DELETION=true`, `GLOBAL_RETENTION_DAYS=10`, `DELETION_MODE=audio_only`, and no `PRESERVE_TEMP_AUDIO`.
4. `docker compose down && docker compose up -d`
5. Logged in as admin in a browser, open `/admin/auto-deletion/stats`. `eligible_count` is how many recordings lose audio at the next 02:00 sweep. If that's more than expected, tag more before 02:00. (A bare `curl` returns 401; the endpoint needs an admin session.)
6. Optional manual sweep, from the browser console on a logged-in page:
   ```javascript
   fetch('/admin/auto-deletion/run', {method: 'POST'}).then(r => r.json()).then(console.log)
   ```
   `deleted_full` **must be 0**. If not, restore from backup immediately.
7. **Advanced Filters → Archived Recordings** should show swept items with transcripts intact.

---

## 5. Backup and restore

```bash
SPEAKR_DIR=~/speakr BACKUP_DIR=~/speakr-backups KEEP=7 \
  ~/meeting-transcription-server/scripts/backup.sh
```

`INCLUDE_AUDIO=0` produces a small DB-and-config-only archive. Speakr is down while the backup runs. Copy archives off the machine; they contain API keys and meeting content.

**Restore:**

```bash
cd ~/speakr
docker compose down
mv instance instance.broken && mv uploads uploads.broken
tar xzf ~/speakr-backups/speakr-YYYYMMDD-HHMMSS.tar.gz
docker compose up -d
```

---

## 6. Updating

1. Read the Speakr release notes for every version between yours and the target. Security fixes are frequent, and some change defaults, such as SSO email verification.
2. Back up.
3. Set the image tag in `docker-compose.yml` to the specific release, not `latest`.
4. `docker compose pull && docker compose down && docker compose up -d`
5. Run the health check.

After an Ollama update, re-run `scripts/start-ollama.sh` and re-check the context length.

---

## 7. Troubleshooting

| Symptom | Likely cause | Action |
|---|---|---|
| `.env` change has no effect | Used `restart` | `docker compose down && docker compose up -d`; check for duplicate keys in `.env` |
| Summary fails with 404 | `TEXT_MODEL_NAME` doesn't match a pulled model | `ollama list`; model names are exact, including the tag |
| Summary fails with connection refused | Ollama not running, or container can't reach host | `scripts/start-ollama.sh`; health check "container can reach Ollama" |
| Summary ignores the end of the meeting | Context fell back to the small default | `ollama ps`; `scripts/start-ollama.sh` |
| Colleague's Record button does nothing | Not on HTTPS, or wrong browser | Use the `.ts.net` URL in Chrome/Edge; check `tailscale serve status` |
| Only one side of a call transcribed | "Share tab audio" not ticked | See USER-GUIDE.md |
| Transcription fails on long files | Groq free-tier quota or file-size limit | Check the Groq console; confirm `CHUNK_LIMIT=20MB` |
| Nothing up after reboot | Session never logged in (FileVault) or Colima service not started | See ADR-007; `brew services list` |
| Admin endpoints return 401 via curl | Needs a browser admin session | Use the browser |
| Disk filling | Video enabled, retention off, or backups on the same disk | `VIDEO_RETENTION=false`; health check; move backups |

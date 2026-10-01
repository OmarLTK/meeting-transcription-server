# meeting-transcription-server

Self-hosted meeting capture, transcription, and summarization for a small team at Toronto Metropolitan University, running on a single Apple Silicon Mac with the language model running locally.

Built on [Speakr](https://github.com/murtaza-nasir/speakr), an open-source transcription web app. **This repository contains no Speakr source code.** It is the deployment around it: configuration, operational scripts, a runbook, and the engineering record of why the system is built the way it is and what broke along the way.

Hard constraint throughout: **zero recurring cost.** Every design choice below is shaped by that.

---

## What it does

A team member opens an HTTPS URL in Chrome or Edge, signs in, and hits **Record** during any meeting (Google Meet, Zoom, in person). Microphone and tab audio are captured in the browser and streamed to the server in 5-second chunks, so a multi-hour recording survives a closed tab or a crash. When the recording stops, the server transcribes it, generates a title and summary, and makes it searchable and chat-able. After 10 days the audio is deleted automatically; the transcript and summary stay.

## Architecture

```
  Browser (Chrome / Edge)
      │  HTTPS — valid cert from Tailscale Serve (required for mic/tab capture)
      ▼
  tailscaled ──────────────► 127.0.0.1:8899   (loopback only; no LAN exposure)
                                  │
                   ┌──────────────┴──────────────┐
                   │  Speakr  (Docker, Colima VM)│──► uploads/   audio, 10-day retention
                   │                             │──► instance/  SQLite: transcripts, summaries
                   └───────┬──────────────┬──────┘
               audio file  │              │  transcript
                           ▼              ▼
                 Groq Whisper API     Ollama — native macOS, Metal GPU
                 (cloud STT, free)    gpt-oss:20b, 32K context
                                      reached via host.docker.internal
```

| Layer | Choice | Runs where |
|---|---|---|
| App | Speakr | Docker container inside Colima's Linux VM |
| Speech-to-text | Groq `whisper-large-v3-turbo` | Cloud (free tier) |
| Summaries / titles / chat | `gpt-oss:20b` via Ollama | Natively on the Mac, Metal-accelerated |
| HTTPS + remote access | Tailscale Serve | Host |
| Hardware | Mac Studio, M2 Max, 96 GB unified memory | Always-on, headless |

## Engineering log: what broke and what fixed it

This is the part worth reading. Each row is a real failure encountered while bringing the system up.

| Symptom | Root cause | Fix |
|---|---|---|
| Every summary of a real meeting failed with HTTP 413 | Summaries originally ran on Groq's free text tier, which caps tokens per minute; a 30-minute transcript alone exceeds the cap | Moved all text generation to a local LLM on the Mac (no rate limit, no per-call cost) |
| Summaries started returning 404 with no config change | The Groq text model the config pointed at was retired upstream | Same fix; a local model can't be deprecated out from under you |
| Risk of summaries silently ignoring the end of a meeting | Ollama's default context window is far smaller than a meeting transcript, and truncation produces no error | `OLLAMA_CONTEXT_LENGTH=32768` set at login via launchd; verified with `ollama ps` and by asking the chat about the final three minutes of a meeting |
| Colleagues' Record button failed; mine worked | Browsers only allow `getUserMedia` / `getDisplayMedia` in a secure context; `localhost` qualifies, a LAN IP over HTTP does not | Tailscale Serve provides a real certificate on a `*.ts.net` name |
| Local transcription in Docker would be CPU-only | Docker on macOS runs a Linux VM with no Metal passthrough | Heavy inference runs natively on the host; the container calls it over HTTP |
| `.env` edits didn't take effect | `docker compose restart` reuses the existing container and does not re-read `env_file` | Always `docker compose down && docker compose up -d` |
| Plain HTTP reachable on the LAN, bypassing HTTPS | Port published as `8899:8899` (all interfaces) | Bound to `127.0.0.1:8899:8899`; health check fails if this regresses |
| Server stayed down after a power cut | FileVault blocks automatic login, so the user session (and Colima) never starts | Documented trade-off; see [DECISIONS.md](docs/DECISIONS.md#adr-007) |
| Transcripts contained loops like "Thank you. Thank you. Thank you." | Whisper hallucinates on long silences | Known limitation, not fixed |
| Transcript is one unbroken paragraph with no speakers | Groq's Whisper does not diarize | Known limitation; options evaluated below |

## Known limitations

These are stated plainly because they are real.

- **No speaker labels.** Action items can't be reliably attributed to a person. Every diarizing option evaluated either costs money (OpenAI `gpt-4o-transcribe-diarize`, AssemblyAI) or requires running WhisperX natively on the Mac plus a small adapter service to match Speakr's ASR API. The native route is free and is the planned next step.
- **Audio leaves the building.** Groq receives every recording for transcription. Deleting local audio after 10 days changes nothing about that.
- **Groq free-tier audio quotas are org-wide.** Heavy concurrent use will hit them. Check current limits in the Groq console.
- **Access is tailnet-only.** Users must be on the Tailscale network. The free Personal plan has a user cap, and off-network access for staff who won't install a VPN client is an open problem. Public exposure via Tailscale Funnel was rejected: Funnel hostnames appear in public Certificate Transparency logs within minutes, and Speakr is alpha software with a recent security-fix history, so its login form would be the only barrier between the internet and recorded meetings.
- **One machine, one copy.** SQLite on a single disk. `scripts/backup.sh` exists; backups must be copied off the machine to mean anything.
- **Upstream is alpha.** Pin the image tag and read release notes before upgrading.

## Repository layout

```
.
├── docker-compose.yml          # Speakr, loopback-bound, host gateway for Ollama
├── .env.example                # All Speakr settings used, commented; copy to .env
├── scripts/
│   ├── start-ollama.sh         # Sets context length, restarts Ollama, preloads model
│   ├── healthcheck.sh          # Read-only check of every layer; non-zero exit on failure
│   └── backup.sh               # Cold backup (DB + config + audio) with pruning
├── launchd/
│   └── local.speakr.ollama.plist   # Runs start-ollama.sh at login
└── docs/
    ├── RUNBOOK.md              # Install, operate, verify, restore, troubleshoot
    ├── DECISIONS.md            # Architecture decision records
    └── USER-GUIDE.md           # One page for the people actually recording
```

## Quick start

Full procedure, including unattended-operation settings, is in [docs/RUNBOOK.md](docs/RUNBOOK.md). The short version on an Apple Silicon Mac:

```bash
brew install colima docker docker-compose tailscale
brew install --cask ollama
colima start && brew services start colima

git clone https://github.com/OmarLTK/meeting-transcription-server.git ~/meeting-transcription-server
mkdir -p ~/speakr && cd ~/speakr
cp ~/meeting-transcription-server/docker-compose.yml .
cp ~/meeting-transcription-server/.env.example .env && nano .env   # add Groq key, admin password

ollama pull gpt-oss:20b
~/meeting-transcription-server/scripts/start-ollama.sh
docker compose up -d
tailscale serve --bg 8899
SPEAKR_DIR=~/speakr ~/meeting-transcription-server/scripts/healthcheck.sh
```

## License

MIT for the contents of this repository. Speakr is licensed separately by its authors.

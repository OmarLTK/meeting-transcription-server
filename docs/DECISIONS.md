# Architecture decision records

Each record states the context, the decision, and the consequences, including the bad ones.

---

## ADR-001: Use Speakr as the application layer

**Context.** The team needed browser-based recording, transcription, summaries, search, tagging, and multi-user accounts. Writing that from scratch was out of scope.

**Decision.** Deploy Speakr (self-hosted, Docker) and treat it as a black box configured through environment variables.

**Consequences.** Fast to stand up and feature-complete. Speakr has **no meeting-bot integration**: it does not join Google Meet or any other call. Its unit of work is audio that already exists, captured by a user's browser, uploaded, or dropped into a watched folder. Upstream is alpha-stage with an active history of security fixes, which drives ADR-005.

---

## ADR-002: Run inference natively, not in Docker

**Context.** Docker on macOS runs containers inside a Linux VM. There is no Metal/GPU passthrough, so any model in a container is CPU-only.

**Decision.** Speakr stays in Docker (Colima). Ollama runs as a native macOS app on Metal. The container reaches it at `host.docker.internal:11434` via `extra_hosts: host-gateway`.

**Consequences.** Full GPU acceleration for the LLM. Two runtimes to keep alive instead of one: the Colima VM and the Ollama app. Both depend on a logged-in user session (see ADR-007). The same pattern is the path to free local diarization: WhisperX native on Metal, called over HTTP.

---

## ADR-003: Speech-to-text on Groq's free tier

**Context.** Zero recurring cost was a hard requirement. Local diarizing ASR on macOS was not a drop-in option at the time: it requires running WhisperX natively and either finding or writing an adapter that speaks Speakr's ASR endpoint API.

**Decision.** Use Groq's OpenAI-compatible Whisper endpoint (`whisper-large-v3-turbo`), with Speakr's app-level chunking at 20 MB.

**Consequences.**
- Fast and free, with no local compute.
- No diarization, so no speaker labels or paragraph breaks.
- Whisper hallucination on silence ("Thank you." loops).
- Org-wide audio quotas on the free tier.
- Every recording is sent to a third party.
- Dependence on a free tier that can change without notice. Groq already broke this deployment once on the text side (ADR-004).

**Revisit when:** someone is available to build and maintain the native WhisperX adapter.

---

## ADR-004: Summaries on a local LLM (`gpt-oss:20b` via Ollama)

**Context.** Summaries originally went to Groq's free text models. Two failures: the tokens-per-minute cap rejected any real meeting transcript (HTTP 413), and the configured model was retired upstream (HTTP 404).

**Decision.** Point `TEXT_MODEL_*` at native Ollama running `gpt-oss:20b`. Set `OLLAMA_CONTEXT_LENGTH=32768` and `OLLAMA_KEEP_ALIVE=24h` via `scripts/start-ollama.sh`, launched at login by launchd.

**Consequences.** No rate limit, no per-call cost, no upstream deprecation risk, and transcripts no longer leave the building for summarization. The machine carries a resident ~20B model. The context length must be verified after every Ollama update or reboot, because a silent fallback to a small default truncates transcripts with no error. `scripts/healthcheck.sh` checks this.

Sizing note: a 30-minute meeting is roughly 4,000 words, or about 5,500–7,000 tokens. 32K leaves headroom for multi-hour meetings plus the summary prompt and output.

---

## ADR-005: Access through Tailscale Serve; container bound to loopback

**Context.** Browser audio capture requires HTTPS. The team also needed access from outside the office network.

**Options evaluated.**

| Option | Cost | Verdict |
|---|---|---|
| Plain HTTP on LAN | Free | Rejected: browsers block capture; no remote access |
| Tailscale Serve (tailnet only) | Free up to the Personal plan's user cap | **Chosen** |
| Tailscale Funnel (public) | Free | Rejected: hostname published in CT logs; alpha app's login form becomes the only barrier |
| Cloudflare Tunnel + Access (email OTP restricted to the university domain) | Needs a domain (~$10–15/yr) | Best technical fit; rejected on the zero-cost constraint |
| Funnel + self-hosted auth gate (Authelia) | Free | Viable fallback; more moving parts |

**Decision.** Tailscale Serve proxies `https://<host>.<tailnet>.ts.net` to `127.0.0.1:8899`. The container publishes on loopback only. Public sharing and open registration are disabled.

**Consequences.** Nothing is reachable from the internet. Every user must install and sign in to Tailscale, a real adoption cost for non-technical staff, and the free plan's user cap limits headcount. Off-network access for everyone else remains an open problem.

---

## ADR-006: 10-day audio retention, transcripts kept

**Context.** Audio is the largest and most sensitive artifact. Transcripts and summaries are the useful ones. Disk: roughly 230 GB free.

**Decision.** `ENABLE_AUTO_DELETION=true`, `GLOBAL_RETENTION_DAYS=10`, `DELETION_MODE=audio_only`. A tag with "Protect from Auto-Deletion" exempts recordings that must keep audio. `VIDEO_RETENTION=false`.

**Consequences.**
- Speakr sweeps daily at 02:00. Audio older than 10 days is removed, and the record moves to the Archived view with transcript, summary, notes, and search intact.
- **Irreversible:** once audio is gone, a bad transcript cannot be re-processed. Ten days is the window to catch Whisper errors on names and jargon.
- The first sweep after enabling strips every recording already past the window. The protected tag must exist and be applied *before* enabling.
- This does not stop audio reaching Groq, the browser's crash-recovery copy, or in-progress server chunks.
- Never delete files from `uploads/` by hand or cron. The database is the source of truth and there is no rescan, so hand-deleted files leave broken records.

---

## ADR-007: Unattended operation vs. disk encryption

**Context.** Colima and the Ollama app run in a user session. After a reboot, nothing starts until a user logs in.

**Decision.** Unresolved; it's a policy call for the system owner, not a technical one. The two options:

- **FileVault on:** the disk is encrypted, but macOS disables automatic login. Any unplanned reboot (power cut) leaves the server down until someone types a password at the machine. `sudo fdesetup authrestart` covers planned reboots only.
- **FileVault off + automatic login:** fully unattended recovery, but physical access to the machine equals access to every recording on it.

Either way: `pmset` is set to never sleep and to restart after power failure, Colima runs as a Homebrew service, and the compose file uses `restart: unless-stopped`. After any change, test with a real `sudo reboot`.

---

## ADR-008: Privacy regime

The users are staff at an Ontario public university, and meetings include students and early-stage founders discussing unreleased ideas. Recordings and transcripts held by a university unit fall under Ontario's FIPPA, not the private-sector PIPEDA framing. That is the main reason for loopback binding, no public sharing, no public exposure, and audio retention. The remaining gap is that audio is processed by a third-party cloud service (ADR-003), which should be disclosed to meeting participants.

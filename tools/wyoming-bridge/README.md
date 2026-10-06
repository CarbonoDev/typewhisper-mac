# Wyoming bridge for MeetingWhisper

Lets Home Assistant use this Mac for speech-to-text. The bridge speaks the
[Wyoming protocol](https://github.com/rhasspy/wyoming) to HA on one side and
MeetingWhisper's loopback REST API on the other, so an HA voice pipeline can
offload ASR onto a machine that can actually run the model.

Standard library Python only — no pip install, no venv.

## Why a bridge instead of exposing the app directly

The app's HTTP server binds to `127.0.0.1` only
(`TypeWhisper/Services/HTTPServer/HTTPServer.swift`), and that restriction is
worth keeping: the same router serves `/v1/meetings`, `/v1/history`, and the
live-segment injection endpoints, so opening it to the LAN would expose the
whole meeting archive to anything on the network. HA also speaks Wyoming, not
HTTP multipart, so it could not call the endpoint regardless.

The bridge is the only process listening on the LAN, and the single capability
it exposes is "transcribe this audio".

## Setup

1. In MeetingWhisper: **Settings › Advanced › API Server**, enable the server.
   The bridge auto-discovers the port and token from `api-discovery.json` in the
   app-support directory, the same way `typewhisper-cli` does — nothing to copy
   by hand.

2. Start the bridge:

   ```bash
   ./wyoming_bridge.py --engine qwen3 --model qwen3-asr-1.7b-6bit
   ```

   macOS will ask to allow incoming connections the first time.

3. In Home Assistant: **Settings › Devices & Services › Add Integration ›
   Wyoming Protocol**, host = this Mac's LAN IP, port = `10300`. Then pick the
   new `stt` entity in your voice pipeline.

## Choose the engine deliberately

Without `--engine`, the bridge uses whatever engine the app has selected, which
may be a cloud provider — meaning every voice command spoken to Home Assistant
gets uploaded. The startup log always prints the engine in use:

```
INFO app status: ready, engine=assemblyai model=universal-3-pro
```

For a home voice assistant you almost certainly want a local engine pinned
explicitly. Measured on this machine with a 1.5s clip:

| engine | cold | warm |
| --- | --- | --- |
| `qwen3` (local) | 1.1s | 0.4s |
| `assemblyai` (cloud) | — | 2.7s |

`GET /v1/models` lists the ids; `downloaded: true` marks what is on disk.

## Options

| flag | default | notes |
| --- | --- | --- |
| `--host` | `0.0.0.0` | use `127.0.0.1` to test without a firewall prompt |
| `--port` | `10300` | the port HA connects to |
| `--engine` / `--model` | app's selection | override per the ids from `/v1/models` |
| `--language` | none | fallback when HA sends no language |
| `--api-port` / `--api-token` | auto-discovered | also `$MEETINGWHISPER_API_TOKEN` |
| `--flavor` | `auto` | `release` or `dev` to pin which build to discover |
| `--max-seconds` | `300` | longer clips are truncated |
| `--timeout` | `120` | API request timeout |
| `--debug` | off | logs every connection and event |

## Run it at login

```bash
cp com.carbono.meetingwhisper.wyoming.plist ~/Library/LaunchAgents/
# edit the paths and flags inside first
launchctl load ~/Library/LaunchAgents/com.carbono.meetingwhisper.wyoming.plist
```

Logs go to `~/Library/Logs/meetingwhisper-wyoming.log`. Unload with
`launchctl unload`.

The bridge tolerates the app being down at startup — it logs a warning and
serves once the app comes back — so login order does not matter.

## Verify

```bash
./wyoming_bridge.py --host 127.0.0.1 --port 10399 --debug &
./test_bridge.py --port 10399                      # 1s of silence
./test_bridge.py --port 10399 --wav speech.wav     # a real 16-bit WAV
```

`test_bridge.py` drives the same event sequence HA does (`describe` →
`transcribe` → `audio-start` → `audio-chunk`× → `audio-stop` → `transcript`)
and asserts on each reply.

## Known behavior

- **A failed transcription returns an empty transcript, not an error.** HA's
  pipeline waits for a `transcript` event; withholding one hangs it until it
  times out. An empty string surfaces as "didn't understand" instead. The real
  cause is always in the bridge log.
- **Silence may 500 from some cloud engines** (AssemblyAI rejects audio with no
  speech). Handled by the rule above.
- **The app must be running and the Mac awake.** The bridge holds no model of
  its own; it is purely a protocol adapter.
- **Discovery order is release, then dev.** If you run both builds, pin the one
  you mean with `--flavor`.

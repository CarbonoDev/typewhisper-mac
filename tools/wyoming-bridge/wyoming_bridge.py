#!/usr/bin/env python3
"""Wyoming ASR bridge for MeetingWhisper.

Speaks the Wyoming protocol to Home Assistant on one side and MeetingWhisper's
loopback REST API (`POST /v1/transcribe`) on the other, so an HA voice pipeline
can offload speech-to-text onto this Mac.

The app's HTTP server binds to 127.0.0.1 only, and deliberately so: the same
router serves /v1/meetings and /v1/history. This bridge is the only thing that
listens on the LAN, and it exposes exactly one capability — transcribe audio.

Standard library only; no pip install, no venv.

    ./wyoming_bridge.py --host 0.0.0.0 --port 10300

Then in Home Assistant: Settings > Devices & Services > Add Integration >
Wyoming Protocol, host = this Mac's LAN IP, port = 10300.
"""

from __future__ import annotations

import argparse
import asyncio
import io
import json
import logging
import os
import sys
import time
import urllib.error
import urllib.request
import uuid
import wave
from pathlib import Path
from typing import Any

LOGGER = logging.getLogger("wyoming-bridge")

DEFAULT_WYOMING_PORT = 10300
DEFAULT_API_PORT = 8978

# Whisper-family language coverage. Home Assistant matches the pipeline's
# language against this list before it will let you pick the entity, so a short
# list here silently locks you out of non-English pipelines.
LANGUAGES = [
    "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs",
    "ca", "cs", "cy", "da", "de", "el", "en", "es", "et", "eu", "fa", "fi",
    "fo", "fr", "gl", "gu", "ha", "haw", "he", "hi", "hr", "ht", "hu", "hy",
    "id", "is", "it", "ja", "jw", "ka", "kk", "km", "kn", "ko", "la", "lb",
    "ln", "lo", "lt", "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt",
    "my", "ne", "nl", "nn", "no", "oc", "pa", "pl", "ps", "pt", "ro", "ru",
    "sa", "sd", "si", "sk", "sl", "sn", "so", "sq", "sr", "su", "sv", "sw",
    "ta", "te", "tg", "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi",
    "yi", "yo", "zh", "yue",
]

ATTRIBUTION = {"name": "MeetingWhisper", "url": "https://github.com/CarbonoDev/typewhisper-mac"}


# --------------------------------------------------------------------------
# Wyoming event framing
# --------------------------------------------------------------------------
#
# Each event is a JSON header line, optionally followed by a JSON `data` blob
# and then a binary payload, with the lengths of both declared in the header:
#
#     {"type": "audio-chunk", "data_length": 61, "payload_length": 2048}\n
#     {"rate": 16000, "width": 2, "channels": 1, "timestamp": 0}<2048 bytes>
#
# Small `data` may also be inlined into the header under a "data" key, which is
# what the reader falls back to when "data_length" is absent.


class Event:
    __slots__ = ("type", "data", "payload")

    def __init__(self, type: str, data: dict[str, Any] | None = None, payload: bytes | None = None):
        self.type = type
        self.data = data or {}
        self.payload = payload


async def read_event(reader: asyncio.StreamReader) -> Event | None:
    header_line = await reader.readline()
    if not header_line:
        return None

    try:
        header = json.loads(header_line)
    except json.JSONDecodeError as err:
        raise ValueError(f"malformed event header: {err}") from err

    data_length = header.get("data_length")
    if data_length is None:
        data = header.get("data") or {}
    else:
        data = json.loads(await reader.readexactly(data_length))

    payload_length = header.get("payload_length")
    payload = await reader.readexactly(payload_length) if payload_length else None

    return Event(header["type"], data, payload)


async def write_event(writer: asyncio.StreamWriter, event: Event) -> None:
    header: dict[str, Any] = {"type": event.type}

    data_bytes = None
    if event.data:
        data_bytes = json.dumps(event.data, ensure_ascii=False).encode("utf-8")
        header["data_length"] = len(data_bytes)
    if event.payload:
        header["payload_length"] = len(event.payload)

    writer.write((json.dumps(header, ensure_ascii=False) + "\n").encode("utf-8"))
    if data_bytes:
        writer.write(data_bytes)
    if event.payload:
        writer.write(event.payload)
    await writer.drain()


# --------------------------------------------------------------------------
# MeetingWhisper REST client
# --------------------------------------------------------------------------


class APIError(Exception):
    pass


class MeetingWhisperClient:
    """Thin client for the app's loopback API.

    Discovery mirrors typewhisper-cli/PortDiscovery.swift: read
    `api-discovery.json` from the app-support directory for the port and token,
    falling back to the bare `api-port` file and then the default port.
    """

    def __init__(
        self,
        port: int | None = None,
        token: str | None = None,
        flavor: str = "auto",
        engine: str | None = None,
        model: str | None = None,
        timeout: float = 120.0,
    ):
        self.engine = engine
        self.model = model
        self.timeout = timeout

        discovered_port, discovered_token = self._discover(flavor)
        self.port = port or discovered_port or DEFAULT_API_PORT
        self.token = token or discovered_token
        self.base_url = f"http://127.0.0.1:{self.port}"

    @staticmethod
    def _support_dirs(flavor: str) -> list[Path]:
        base = Path.home() / "Library" / "Application Support"
        names = {
            "release": ["MeetingWhisper"],
            "dev": ["MeetingWhisper-Dev"],
            "auto": ["MeetingWhisper", "MeetingWhisper-Dev"],
        }[flavor]
        return [base / name for name in names]

    def _discover(self, flavor: str) -> tuple[int | None, str | None]:
        for directory in self._support_dirs(flavor):
            discovery_file = directory / "api-discovery.json"
            try:
                document = json.loads(discovery_file.read_text())
                if int(document.get("port", 0)) > 0:
                    token = (document.get("token") or "").strip() or None
                    LOGGER.debug("discovered API via %s", discovery_file)
                    return int(document["port"]), token
            except (OSError, ValueError, KeyError):
                pass

            try:
                port = int((directory / "api-port").read_text().strip())
                if port > 0:
                    return port, None
            except (OSError, ValueError):
                pass

        return None, None

    def _request(self, method: str, path: str, body: bytes | None = None, content_type: str | None = None) -> Any:
        request = urllib.request.Request(f"{self.base_url}{path}", data=body, method=method)
        if content_type:
            request.add_header("Content-Type", content_type)
        if self.token:
            request.add_header("Authorization", f"Bearer {self.token}")

        try:
            with urllib.request.urlopen(request, timeout=self.timeout) as response:
                return json.loads(response.read())
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", "replace")[:500]
            raise APIError(f"{method} {path} -> HTTP {err.code}: {detail}") from err
        except urllib.error.URLError as err:
            raise APIError(f"{method} {path} -> {err.reason} (is MeetingWhisper running with the API server enabled?)") from err

    def status(self) -> dict[str, Any]:
        return self._request("GET", "/v1/status")

    def models(self) -> list[dict[str, Any]]:
        return self._request("GET", "/v1/models").get("models", [])

    def transcribe(self, wav_bytes: bytes, language: str | None = None) -> dict[str, Any]:
        fields: dict[str, str] = {}
        if language:
            fields["language"] = language
        if self.engine:
            fields["engine"] = self.engine
        if self.model:
            fields["model"] = self.model

        boundary = f"----MeetingWhisperBridge{uuid.uuid4().hex}"
        body = self._multipart(boundary, fields, wav_bytes)
        # await_download=1 makes a cold model download block instead of erroring,
        # which is what you want for an unattended bridge.
        return self._request(
            "POST",
            "/v1/transcribe?await_download=1",
            body=body,
            content_type=f"multipart/form-data; boundary={boundary}",
        )

    @staticmethod
    def _multipart(boundary: str, fields: dict[str, str], wav_bytes: bytes) -> bytes:
        buffer = io.BytesIO()
        for name, value in fields.items():
            buffer.write(f"--{boundary}\r\n".encode())
            buffer.write(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
            buffer.write(value.encode("utf-8"))
            buffer.write(b"\r\n")

        buffer.write(f"--{boundary}\r\n".encode())
        buffer.write(b'Content-Disposition: form-data; name="file"; filename="audio.wav"\r\n')
        buffer.write(b"Content-Type: audio/wav\r\n\r\n")
        buffer.write(wav_bytes)
        buffer.write(b"\r\n")
        buffer.write(f"--{boundary}--\r\n".encode())
        return buffer.getvalue()


def pcm_to_wav(pcm: bytes, rate: int, width: int, channels: int) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as wav_file:
        wav_file.setnchannels(channels)
        wav_file.setsampwidth(width)
        wav_file.setframerate(rate)
        wav_file.writeframes(pcm)
    return buffer.getvalue()


# --------------------------------------------------------------------------
# Wyoming server
# --------------------------------------------------------------------------


class BridgeServer:
    def __init__(self, client: MeetingWhisperClient, default_language: str | None, max_seconds: float):
        self.client = client
        self.default_language = default_language
        self.max_seconds = max_seconds
        self._info_cache: dict[str, Any] | None = None

    async def handle(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        peer = writer.get_extra_info("peername")
        LOGGER.debug("connection from %s", peer)

        chunks: list[bytes] = []
        rate, width, channels = 16000, 2, 1
        language = self.default_language
        recording = False

        try:
            while True:
                event = await read_event(reader)
                if event is None:
                    break

                if event.type == "describe":
                    await write_event(writer, Event("info", await self._info()))

                elif event.type == "transcribe":
                    # HA sends the pipeline language here, ahead of the audio.
                    language = event.data.get("language") or self.default_language

                elif event.type == "audio-start":
                    rate = int(event.data.get("rate", rate))
                    width = int(event.data.get("width", width))
                    channels = int(event.data.get("channels", channels))
                    chunks = []
                    recording = True

                elif event.type == "audio-chunk":
                    if not recording:
                        # Some clients stream without an explicit audio-start.
                        rate = int(event.data.get("rate", rate))
                        width = int(event.data.get("width", width))
                        channels = int(event.data.get("channels", channels))
                        recording = True
                    if event.payload:
                        chunks.append(event.payload)

                elif event.type == "audio-stop":
                    recording = False
                    text = await self._transcribe(b"".join(chunks), rate, width, channels, language)
                    chunks = []
                    await write_event(writer, Event("transcript", {"text": text}))

                else:
                    LOGGER.debug("ignoring event %s", event.type)

        except (asyncio.IncompleteReadError, ConnectionResetError, BrokenPipeError):
            LOGGER.debug("connection from %s dropped", peer)
        except Exception:
            LOGGER.exception("error handling connection from %s", peer)
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionResetError, BrokenPipeError):
                pass

    async def _transcribe(self, pcm: bytes, rate: int, width: int, channels: int, language: str | None) -> str:
        if not pcm:
            LOGGER.warning("audio-stop with no audio; returning empty transcript")
            return ""

        seconds = len(pcm) / max(1, rate * width * channels)
        if seconds > self.max_seconds:
            keep = int(self.max_seconds * rate * width * channels)
            LOGGER.warning("clip is %.1fs, truncating to %.0fs", seconds, self.max_seconds)
            pcm = pcm[:keep]
            seconds = self.max_seconds

        wav_bytes = pcm_to_wav(pcm, rate, width, channels)
        started = time.monotonic()
        try:
            result = await asyncio.to_thread(self.client.transcribe, wav_bytes, language)
        except APIError as err:
            # A transcript event is still owed, or HA's pipeline hangs until it
            # times out. An empty one surfaces as "didn't understand".
            LOGGER.error("transcription failed: %s", err)
            return ""

        text = (result.get("text") or "").strip()
        LOGGER.info(
            "%.1fs audio -> %.1fs via %s: %r",
            seconds,
            time.monotonic() - started,
            result.get("engine", "?"),
            text,
        )
        return text

    async def _info(self) -> dict[str, Any]:
        if self._info_cache is not None:
            return self._info_cache

        try:
            models = await asyncio.to_thread(self.client.models)
        except APIError as err:
            LOGGER.warning("could not read model catalog (%s); advertising a generic model", err)
            models = []

        # Advertise the engine the bridge will actually use: an explicit
        # override if one was given, otherwise whatever the app has selected.
        if self.client.engine:
            usable = [m for m in models if m["engine"] == self.client.engine]
            if self.client.model:
                usable = [m for m in usable if m["id"] == self.client.model]
        else:
            usable = [m for m in models if m.get("selected")]

        entries = [
            {
                "name": model["id"],
                "description": f"{model.get('name', model['id'])} ({model['engine']})",
                "attribution": ATTRIBUTION,
                "installed": True,
                "languages": LANGUAGES,
                "version": None,
            }
            for model in usable
        ] or [
            {
                "name": "meetingwhisper",
                "description": "MeetingWhisper's selected transcription engine",
                "attribution": ATTRIBUTION,
                "installed": True,
                "languages": LANGUAGES,
                "version": None,
            }
        ]

        self._info_cache = {
            "asr": [
                {
                    "name": "meetingwhisper",
                    "description": "MeetingWhisper speech-to-text",
                    "attribution": ATTRIBUTION,
                    "installed": True,
                    "version": None,
                    "models": entries,
                }
            ],
            "tts": [],
            "handle": [],
            "intent": [],
            "wake": [],
            "satellite": None,
        }
        return self._info_cache


# --------------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0", help="address to listen on for Home Assistant (default: %(default)s)")
    parser.add_argument("--port", type=int, default=DEFAULT_WYOMING_PORT, help="Wyoming port (default: %(default)s)")
    parser.add_argument("--api-port", type=int, default=None, help="MeetingWhisper API port (default: auto-discover)")
    parser.add_argument("--api-token", default=os.environ.get("MEETINGWHISPER_API_TOKEN"), help="API token (default: auto-discover, or $MEETINGWHISPER_API_TOKEN)")
    parser.add_argument("--flavor", choices=["auto", "release", "dev"], default="auto", help="which build's app-support directory to discover from (default: %(default)s)")
    parser.add_argument("--engine", default=None, help="engine id override, e.g. qwen3 (default: the app's selected engine)")
    parser.add_argument("--model", default=None, help="model id override, e.g. qwen3-asr-1.7b-6bit")
    parser.add_argument("--language", default=None, help="language code to use when Home Assistant does not send one")
    parser.add_argument("--max-seconds", type=float, default=300.0, help="truncate clips longer than this (default: %(default)s)")
    parser.add_argument("--timeout", type=float, default=120.0, help="API request timeout in seconds (default: %(default)s)")
    parser.add_argument("--debug", action="store_true", help="verbose logging")
    return parser.parse_args(argv)


async def run(args: argparse.Namespace) -> int:
    client = MeetingWhisperClient(
        port=args.api_port,
        token=args.api_token,
        flavor=args.flavor,
        engine=args.engine,
        model=args.model,
        timeout=args.timeout,
    )

    LOGGER.info("MeetingWhisper API at %s (token %s)", client.base_url, "yes" if client.token else "none")
    try:
        status = await asyncio.to_thread(client.status)
        engine = args.engine or status.get("engine")
        model = args.model or status.get("model")
        LOGGER.info("app status: %s, engine=%s model=%s", status.get("status"), engine, model)
        if status.get("status") != "ready" and not args.engine:
            LOGGER.warning("app reports no ready model; transcription will fail until one is selected")
    except APIError as err:
        LOGGER.warning("could not reach the app yet: %s", err)
        LOGGER.warning("starting anyway; requests will fail until the app is running")

    server = BridgeServer(client, args.language, args.max_seconds)
    listener = await asyncio.start_server(server.handle, args.host, args.port)
    LOGGER.info("Wyoming ASR listening on %s:%d", args.host, args.port)

    async with listener:
        await listener.serve_forever()
    return 0


def main() -> int:
    args = parse_args()
    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    try:
        return asyncio.run(run(args))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())

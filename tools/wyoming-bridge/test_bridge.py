#!/usr/bin/env python3
"""End-to-end check for the Wyoming bridge.

Drives a running bridge the way Home Assistant's Wyoming integration does:
`describe` for discovery, then `transcribe` / `audio-start` / `audio-chunk` /
`audio-stop` and wait for a `transcript`.

    ./wyoming_bridge.py --debug &
    ./test_bridge.py --wav some-speech.wav

With no --wav it sends a second of silence, which exercises the whole path
(framing, WAV wrapping, the POST, the reply) without asserting on the text.
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import wave

from wyoming_bridge import Event, read_event, write_event

CHUNK_SAMPLES = 1024


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=10300)
    parser.add_argument("--wav", default=None, help="16-bit WAV to send (default: 1s of silence)")
    parser.add_argument("--language", default=None)
    args = parser.parse_args()

    if args.wav:
        with wave.open(args.wav, "rb") as wav_file:
            rate = wav_file.getframerate()
            width = wav_file.getsampwidth()
            channels = wav_file.getnchannels()
            pcm = wav_file.readframes(wav_file.getnframes())
        print(f"loaded {args.wav}: {rate}Hz {width*8}-bit {channels}ch, {len(pcm)/(rate*width*channels):.1f}s")
    else:
        rate, width, channels = 16000, 2, 1
        pcm = b"\x00\x00" * rate
        print("sending 1s of silence")

    reader, writer = await asyncio.open_connection(args.host, args.port)

    await write_event(writer, Event("describe"))
    info = await read_event(reader)
    assert info is not None and info.type == "info", f"expected info, got {info and info.type}"
    services = info.data.get("asr", [])
    assert services, "info advertised no ASR service"
    models = [m["name"] for m in services[0].get("models", [])]
    print(f"info: asr={services[0]['name']} models={models}")
    assert models, "ASR service advertised no models"

    if args.language:
        await write_event(writer, Event("transcribe", {"language": args.language}))

    audio_data = {"rate": rate, "width": width, "channels": channels}
    await write_event(writer, Event("audio-start", {**audio_data, "timestamp": 0}))

    frame = width * channels
    step = CHUNK_SAMPLES * frame
    for offset in range(0, len(pcm), step):
        await write_event(
            writer,
            Event("audio-chunk", {**audio_data, "timestamp": offset // frame}, pcm[offset : offset + step]),
        )
    await write_event(writer, Event("audio-stop", {"timestamp": len(pcm) // frame}))

    transcript = await asyncio.wait_for(read_event(reader), timeout=180)
    assert transcript is not None and transcript.type == "transcript", f"expected transcript, got {transcript and transcript.type}"
    print(f"transcript: {transcript.data.get('text')!r}")

    writer.close()
    await writer.wait_closed()
    print("PASS")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

#!/usr/bin/env python3
"""
Standalone speaker diarization sidecar for TypeWhisper.

Runs pyannote/speaker-diarization-3.1 on an audio file and emits speaker
segments as JSON to stdout. All diagnostic logging goes to stderr so stdout
stays clean JSON for the calling process to parse.

Usage:
    diarize_sidecar.py <audio_path> [--speakers N] [--hf-token TOKEN]

Requires:
    - ffmpeg on PATH
    - pyannote.audio + torch installed
    - HF token via --hf-token or HF_TOKEN env var, with model access at
      https://huggingface.co/pyannote/speaker-diarization-3.1
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile


def log(msg: str) -> None:
    print(f"[diarize] {msg}", file=sys.stderr, flush=True)


def diarize(audio_path: str, token: str, num_speakers=None) -> list:
    from pyannote.audio import Pipeline
    import torch

    if torch.cuda.is_available():
        device = "cuda"
    elif getattr(torch.backends, "mps", None) and torch.backends.mps.is_available():
        device = "mps"
    else:
        device = "cpu"

    log("Loading pipeline...")
    pipeline = Pipeline.from_pretrained("pyannote/speaker-diarization-3.1", token=token)
    if pipeline is None:
        raise RuntimeError(
            "Failed to load pipeline — check HF token and model access at "
            "https://huggingface.co/pyannote/speaker-diarization-3.1"
        )
    pipeline = pipeline.to(torch.device(device))

    # Convert to 16kHz mono WAV — torchcodec handles WAV more reliably than
    # compressed formats.
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        tmp_wav = tmp.name
    subprocess.run(
        ["ffmpeg", "-y", "-i", str(audio_path), "-ar", "16000", "-ac", "1", tmp_wav],
        check=True,
        capture_output=True,
    )

    log(f"Running on {device}...")
    diar_kwargs = {"num_speakers": num_speakers} if num_speakers else {}

    try:
        diarization = pipeline(tmp_wav, **diar_kwargs)
    finally:
        os.unlink(tmp_wav)

    # Handle both old (Annotation with itertracks) and new (pyannote community
    # object exposing .speaker_diarization) API shapes.
    if hasattr(diarization, "itertracks"):
        annotation = diarization
    elif hasattr(diarization, "speaker_diarization"):
        annotation = diarization.speaker_diarization
    else:
        raise RuntimeError(
            f"Unrecognized diarization output type: {type(diarization)} "
            f"Attributes: {[a for a in dir(diarization) if not a.startswith('_')]}"
        )

    segments = [
        {"start": float(turn.start), "end": float(turn.end), "speaker": speaker}
        for turn, _, speaker in annotation.itertracks(yield_label=True)
    ]
    log(f"Done — {len(segments)} segments, {len(set(s['speaker'] for s in segments))} speakers")
    return segments


def main() -> int:
    parser = argparse.ArgumentParser(description="Speaker diarization sidecar")
    parser.add_argument("audio_path", help="Path to the audio file to diarize")
    parser.add_argument("--speakers", type=int, default=None, help="Exact number of speakers")
    parser.add_argument("--hf-token", default=None, help="Hugging Face token (else HF_TOKEN env)")
    args = parser.parse_args()

    token = args.hf_token or os.environ.get("HF_TOKEN")
    if not token:
        log("No HF token provided (pass --hf-token or set HF_TOKEN)")
        return 1

    if not os.path.isfile(args.audio_path):
        log(f"Audio file not found: {args.audio_path}")
        return 1

    try:
        segments = diarize(args.audio_path, token, args.speakers)
    except subprocess.CalledProcessError as e:
        stderr = e.stderr.decode("utf-8", "replace") if e.stderr else ""
        log(f"ffmpeg failed: {stderr}")
        return 1
    except Exception as e:
        log(f"Diarization failed: {e}")
        return 1

    json.dump(segments, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())

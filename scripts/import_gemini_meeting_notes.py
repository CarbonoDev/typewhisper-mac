#!/usr/bin/env python3
"""Import Google Meet "Notas de Gemini" markdown exports as TypeWhisper meetings.

A Gemini export bundles two documents in one file: the notes Gemini wrote (Resumen /
Detalles / Pasos siguientes recomendados) and the raw transcript (``### **HH:MM:SS**`` blocks of
``**Speaker:** utterance`` lines). The notes half is not readable by ``TranscriptFileParser``,
so this script splits an export into the shape the local HTTP API wants:

* transcript -> posted **verbatim** as the ``text`` field. The app already parses this exact
  format natively (``TranscriptFileParser.parseGeminiNotes``, reached through
  ``POST /v1/meetings/import-transcript`` -> ``MeetingImportService.importTranscriptText``),
  including the per-turn time interpolation inside each ``### **HH:MM:SS**`` block, so this
  script only *locates* the section and hands the raw markdown over — it does not re-parse it;
* Resumen -> the ``summary`` field (stored verbatim as the meeting's Summary output);
* Detalles + Pasos siguientes -> the ``extended`` field;
* the ``Invitados`` line -> ``attendees`` (struck-through invitees, i.e. the ones who did not
  attend, are dropped unless ``--include-absent``);
* the filename's ``2026_03_10_11_00 CST`` stamp -> the meeting date.

Usage:
    python3 scripts/import_gemini_meeting_notes.py ~/Downloads/markdown_notes/*.md \\
        --folder Binnacle --language es --match-calendar --self-email me@example.com
    python3 scripts/import_gemini_meeting_notes.py FILE --dry-run --dump-dir /tmp/preview
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys
import urllib.error
import urllib.request

# --------------------------------------------------------------------------------------
# Parsing
# --------------------------------------------------------------------------------------

# Fixed offsets for the abbreviations Google stamps into export filenames. Mirrors
# ImportedMeetingTitle.fixedOffsetHours: the stamp states an offset, so honor it literally
# instead of letting a zone database re-apply DST to a fixed-offset region.
FIXED_OFFSET_HOURS = {
    "UTC": 0, "GMT": 0, "Z": 0,
    "EST": -5, "EDT": -4,
    "CST": -6, "CDT": -5,
    "MST": -7, "MDT": -6,
    "PST": -8, "PDT": -7,
}

FILENAME_STAMP = re.compile(r"(\d{4})_(\d{2})_(\d{2})[_ ](\d{2})_(\d{2})(?:[_ ]([A-Za-z]{2,5}))?")

# The transcript half's banner. Real exports bold every heading and backslash-escape the dash
# (``## **Seguimiento Fase 2 IA \- Transcripción**``); both markers are optional so a plain
# ``## Title - Transcript`` export still splits. Group 1 is the title without the suffix.
TRANSCRIPT_HEADING = re.compile(
    r"^##[ \t]+\*{0,2}[ \t]*(.*?)[ \t]*\\?[-–—][ \t]*Transcrip(?:ci[óo]n|t(?:ion)?)[ \t]*\*{0,2}[ \t]*$",
    re.MULTILINE,
)
# Report/guard only: the script counts speaker turns to decide whether a section is worth posting
# and to label the dry run. Turn *parsing* belongs to TranscriptFileParser.parseGeminiNotes.
TURN_LINE = re.compile(r"^\*\*[^*]+?:\*\*\s*\S")
MD_LINK = re.compile(r"\[([^\]]*)\]\([^)]*\)")
ATTENDEE_LINK = re.compile(r"\[(?P<name>[^\]]*)\]\(mailto:(?P<email>[^)]+)\)")

# Gemini's own footer/disclaimer chatter — never part of the meeting's content.
BOILERPLATE_PREFIXES = (
    "*Revisa las notas de Gemini",
    "*Danos tu opinión",
    "*Esta transcripción editable",
    "📖 Transcripción",
)


def _clean_markdown(text: str) -> str:
    """Strip the Docs-export artifacts: underline spans, link targets, escapes, hard breaks."""
    text = text.replace("\xa0", " ")
    text = re.sub(r"</?span[^>]*>", "", text)
    text = MD_LINK.sub(r"\1", text)          # keep the label, drop the (#section) target
    text = re.sub(r"~~(.*?)~~", r"\1", text)
    # Same escape set as TranscriptFileParser.unescapeMarkdown — exports escape `\-` and `\.`
    # too, not just the emphasis characters. Bold markers are deliberately *kept*: notes bodies
    # use them for real emphasis (`**Gestión de Errores**`) and are stored as markdown.
    text = re.sub(r"\\([\\`*_{}\[\]()#+\-.!>~|])", r"\1", text)
    return text


def _heading_text(line: str, level: int) -> str | None:
    """Inner text of a ``##``/``###`` heading, or None. Real exports bold every heading
    (``### **Resumen**``); older exports do not, so the markers are optional."""
    match = re.match(rf"^#{{{level}}}[ \t]+(.*?)[ \t]*$", line)
    if not match:
        return None
    inner = match.group(1).strip()
    bold = re.match(r"^\*\*(.+?)\*\*$", inner)
    if bold:
        inner = bold.group(1).strip()
    return _clean_markdown(inner).strip()


def parse_stamp(name: str) -> str | None:
    """``…__2026_03_10_11_00_CST__…`` -> ``2026-03-10T11:00:00-06:00``."""
    match = FILENAME_STAMP.search(name)
    if not match:
        return None
    year, month, day, hour, minute, zone = match.groups()
    hours = FIXED_OFFSET_HOURS.get((zone or "").upper())
    if hours is None:
        offset = "Z" if zone else _local_offset()
    else:
        offset = "Z" if hours == 0 else f"{'+' if hours >= 0 else '-'}{abs(hours):02d}:00"
    return f"{year}-{month}-{day}T{hour}:{minute}:00{offset}"


def _local_offset() -> str:
    import datetime

    delta = datetime.datetime.now().astimezone().utcoffset() or datetime.timedelta(0)
    total = int(delta.total_seconds())
    sign = "+" if total >= 0 else "-"
    total = abs(total)
    return f"{sign}{total // 3600:02d}:{(total % 3600) // 60:02d}"


def parse_attendees(lines: list[str], include_absent: bool, self_email: str | None) -> list[dict]:
    """Read the ``Invitado(s)`` roster. Struck-through names are invitees who did not attend."""
    attendees: list[dict] = []
    seen: set[str] = set()
    for line in lines:
        if not re.match(r"^Invitad[oa]s?\s", line.strip()):
            continue
        for match in ATTENDEE_LINK.finditer(line):
            raw_name = match.group("name")
            absent = "~~" in raw_name
            if absent and not include_absent:
                continue
            name = _clean_markdown(raw_name).strip()
            email = match.group("email").strip()
            key = (email or name).lower()
            if not name or key in seen:
                continue
            seen.add(key)
            entry = {"name": name, "email": email}
            if self_email and email.lower() == self_email.lower():
                entry["is_self"] = True
            attendees.append(entry)
        break
    return attendees


def _clean_block(raw_lines: list[str]) -> str:
    """Normalize one notes section: unwrap Docs' ``  - > `` blockquote bullets, drop chatter."""
    out: list[str] = []
    for raw in raw_lines:
        line = _clean_markdown(raw).rstrip()
        stripped = line.strip()
        if not stripped:
            if out and out[-1] != "":
                out.append("")
            continue
        if stripped.startswith(BOILERPLATE_PREFIXES):
            continue
        bullet = re.match(r"^\s*-\s*>\s*(.*)$", line)       # "  - > text"  -> top-level bullet
        continuation = re.match(r"^\s+>\s*(.*)$", line)     # "    > text"  -> sibling bullet
        if bullet:
            out.append(f"- {bullet.group(1).strip()}")
        elif continuation:
            out.append(f"- {continuation.group(1).strip()}")
        else:
            out.append(stripped)
    while out and out[-1] == "":
        out.pop()
    text = "\n".join(out)
    # Docs writes each blockquote bullet as its own paragraph; tighten consecutive bullets so
    # the list renders as a list rather than a run of spaced-out paragraphs.
    while True:
        tightened = re.sub(r"(?m)^(- .*)\n\n(?=- )", r"\1\n", text)
        if tightened == text:
            return text
        text = tightened


def count_turns(transcript: str) -> int:
    """How many ``**Speaker:** utterance`` turns the section carries. Used to decide whether the
    section is worth posting and to label the dry run — not to parse it."""
    return sum(1 for line in transcript.split("\n") if TURN_LINE.match(line.strip()))


def parse_export(text: str, filename: str, include_absent: bool = False,
                 self_email: str | None = None) -> dict:
    """Split one Gemini export into the fields the import endpoint takes."""
    text = text.replace("\r\n", "\n").replace("\r", "\n")
    split = TRANSCRIPT_HEADING.search(text)
    notes_part = text[: split.start()] if split else text
    # The transcript section is handed to the app verbatim, banner line included: the heading is
    # one of the two signals TranscriptFileParser uses to recognize a Gemini export.
    transcript_part = text[split.start():].strip() if split else ""

    lines = notes_part.split("\n")
    title = ""
    for line in lines:
        heading = _heading_text(line, 2)
        if heading:
            title = heading
            break
    # A transcript-only export has no notes half to title it; the banner carries the meeting name.
    if not title and split:
        title = _clean_markdown(split.group(1)).strip()
    if not title:
        title = os.path.splitext(os.path.basename(filename))[0]

    sections: dict[str, list[str]] = {}
    current: str | None = None
    for line in lines:
        # Gemini's footer ("Revisa las notas…") ends the notes; what follows is the export's own
        # chrome — a repeated date line and the transcript's banner — not meeting content.
        if line.strip().startswith(BOILERPLATE_PREFIXES):
            break
        heading = _heading_text(line, 3)
        if heading is not None:
            current = heading.lower()
            sections[current] = []
        elif current is not None:
            sections[current].append(line)

    summary = _clean_block(sections.get("resumen", []))
    extended_parts = []
    details = _clean_block(sections.get("detalles", []))
    if details:
        extended_parts.append(f"## Detalles\n\n{details}")
    steps = _clean_block(sections.get("pasos siguientes recomendados", []))
    if steps:
        extended_parts.append(f"## Pasos siguientes recomendados\n\n{steps}")

    return {
        "title": title,
        "date": parse_stamp(os.path.basename(filename)),
        "attendees": parse_attendees(lines, include_absent, self_email),
        "summary": summary,
        "extended": "\n\n".join(extended_parts),
        "text": transcript_part,
    }


# --------------------------------------------------------------------------------------
# Import
# --------------------------------------------------------------------------------------


def post_import(base_url: str, payload: dict, token: str | None) -> dict:
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/v1/meetings/import-transcript",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=120) as response:
        return json.loads(response.read().decode("utf-8"))


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="+", help="Gemini export .md files (globs allowed)")
    parser.add_argument("--folder", help="Meeting folder path, e.g. Binnacle")
    parser.add_argument("--tags", help="Comma-separated tags")
    parser.add_argument("--language", help="Language code stored on the meeting, e.g. es")
    parser.add_argument("--match-calendar", action="store_true", help="Auto-link a historical calendar event")
    parser.add_argument("--include-absent", action="store_true", help="Also import struck-through invitees")
    parser.add_argument("--self-email", help="Mark this attendee as the device owner (is_self)")
    parser.add_argument("--url", default="http://127.0.0.1:8978", help="API base URL")
    parser.add_argument("--token", help="API token (when authentication is enabled)")
    parser.add_argument("--dry-run", action="store_true", help="Parse and report; import nothing")
    parser.add_argument("--dump-dir", help="Write the parsed payloads here for inspection")
    args = parser.parse_args(argv)

    paths: list[str] = []
    for pattern in args.files:
        matches = sorted(glob.glob(os.path.expanduser(pattern)))
        paths.extend(matches or [os.path.expanduser(pattern)])

    failures = 0
    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                raw = handle.read()
        except OSError as error:
            print(f"SKIP {os.path.basename(path)}: {error}", file=sys.stderr)
            failures += 1
            continue

        parsed = parse_export(raw, path, include_absent=args.include_absent, self_email=args.self_email)
        turns = count_turns(parsed["text"])
        label = f"{parsed['title']} @ {parsed['date']}"
        if not turns:
            print(f"SKIP {os.path.basename(path)}: no transcript turns found", file=sys.stderr)
            failures += 1
            continue

        payload = {key: value for key, value in parsed.items() if value}
        if args.folder:
            payload["folder"] = args.folder
        if args.tags:
            payload["tags"] = [tag.strip() for tag in args.tags.split(",") if tag.strip()]
        if args.language:
            payload["language"] = args.language
        if args.match_calendar:
            payload["match_calendar"] = True

        if args.dump_dir:
            os.makedirs(args.dump_dir, exist_ok=True)
            target = os.path.join(args.dump_dir, os.path.basename(path) + ".json")
            with open(target, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, ensure_ascii=False, indent=2)

        if args.dry_run:
            print(f"DRY  {label} — {turns} turns, {len(parsed['attendees'])} attendees, "
                  f"summary {len(parsed['summary'])} chars, extended {len(parsed['extended'])} chars")
            continue

        try:
            result = post_import(args.url, payload, args.token)
        except urllib.error.HTTPError as error:
            print(f"FAIL {label}: HTTP {error.code} {error.read().decode('utf-8', 'replace')}", file=sys.stderr)
            failures += 1
            continue
        except OSError as error:
            print(f"FAIL {label}: {error}", file=sys.stderr)
            failures += 1
            continue

        matched = result.get("matched_event")
        suffix = f" [calendar: {matched['title']} {matched['confidence']:.2f}]" if matched else ""
        print(f"OK   {label} — {turns} turns → {result['id']}{suffix}")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

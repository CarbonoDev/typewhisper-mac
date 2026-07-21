#!/usr/bin/env python3
"""Tests for the Gemini meeting-notes export parser."""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from import_gemini_meeting_notes import parse_export, parse_stamp, parse_transcript

EXPORT = """10 mar 2026

## Llamada Semanal Dirección-TI

Invitados [<span class="underline">Hugo Anaya</span>](mailto:hanaya@example.mx) \
[<span class="underline">Marco Rivadeneyra</span>](mailto:marco@example.mx) \
[~~<span class="underline">Juan Carlos Sánchez</span>~~](mailto:jsanchez@example.mx)

Archivos adjuntos [<span class="underline">Llamada Semanal</span>](https://www.google.com/calendar/event?eid=abc)

### Resumen

Ajustes de carga laboral dominaron la sesión.

**Gestión de Errores**
El error crítico sigue sin resolverse.

### Detalles

  - > **Carga Laboral**: Se discutió reducir la carga ([<span class="underline">00:00:00</span>](#section)).

  - > **Bugs**: Hugo toma el \\*bug\\* crítico ([<span class="underline">00:01:00</span>](#section-1)).

### Pasos siguientes recomendados

  - > Hugo Anaya tomará el bug crítico.

    > Hugo Anaya actualizará el ticket diariamente.

*Revisa las notas de Gemini para asegurarte de que sean correctas.* [*<span class="underline">Consejos</span>*](https://support.google.com/meet)

📖 Transcripción

10 mar 2026

## Llamada Semanal Dirección-TI - Transcripción

### 00:00:00

\xa0
**Hugo Anaya:** Hola a todos.
**Karim Darwich:** Hola.


### 00:01:00

**Hugo Anaya:** Empecemos con los bugs.

### La transcripción finalizó después de 00:02:00

*Esta transcripción editable se ha generado por ordenador y puede contener errores.*
"""


class ParseStampTests(unittest.TestCase):
    def test_named_zone_uses_its_stated_fixed_offset(self) -> None:
        self.assertEqual(
            parse_stamp("Llamada__2026_03_10_11_00_CST__Notas_de_Gemini.md"),
            "2026-03-10T11:00:00-06:00",
        )

    def test_utc_stamp_collapses_to_z(self) -> None:
        self.assertEqual(parse_stamp("Sync__2026_03_10_11_00_UTC.md"), "2026-03-10T11:00:00Z")

    def test_filename_without_a_stamp_yields_no_date(self) -> None:
        self.assertIsNone(parse_stamp("just-a-note.md"))


class ParseTranscriptTests(unittest.TestCase):
    def test_turns_are_spread_across_their_block(self) -> None:
        parsed = parse_transcript(
            "### 00:00:00\n\n**A:** aaaaa\n**B:** bbbbb\n\n### 00:00:10\n\n**A:** end\n"
        )
        # Two equal-length turns split the 10s block in half; the trailing block has no
        # successor, so it falls back to a one-minute span.
        self.assertEqual(
            parsed.split("\n"),
            ["00:00:00 A: aaaaa", "00:00:05 B: bbbbb", "00:00:10 A: end"],
        )

    def test_end_marker_bounds_the_final_block(self) -> None:
        parsed = parse_transcript(
            "### 00:00:00\n**A:** one\n**B:** two\n### La transcripción finalizó después de 00:00:20\n"
        )
        self.assertEqual(parsed.split("\n"), ["00:00:00 A: one", "00:00:10 B: two"])

    def test_boilerplate_and_blockless_lines_are_dropped(self) -> None:
        parsed = parse_transcript(
            "**A:** stray turn before any block\n### 00:00:00\n"
            "*Esta transcripción editable se ha generado por ordenador.*\n**A:** real turn\n"
        )
        self.assertEqual(parsed, "00:00:00 A: real turn")


class ParseExportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.parsed = parse_export(
            EXPORT,
            "Llamada_Semanal_Direccio_nTI__2026_03_10_11_00_CST__Notas_de_Gemini.md",
            self_email="marco@example.mx",
        )

    def test_title_comes_from_the_document_not_the_filename(self) -> None:
        self.assertEqual(self.parsed["title"], "Llamada Semanal Dirección-TI")

    def test_date_comes_from_the_filename_stamp(self) -> None:
        self.assertEqual(self.parsed["date"], "2026-03-10T11:00:00-06:00")

    def test_struck_through_invitees_are_absent_and_self_is_flagged(self) -> None:
        self.assertEqual(
            self.parsed["attendees"],
            [
                {"name": "Hugo Anaya", "email": "hanaya@example.mx"},
                {"name": "Marco Rivadeneyra", "email": "marco@example.mx", "is_self": True},
            ],
        )

    def test_absent_invitees_can_be_kept(self) -> None:
        parsed = parse_export(EXPORT, "x__2026_03_10_11_00_CST.md", include_absent=True)
        self.assertEqual([entry["name"] for entry in parsed["attendees"]][-1], "Juan Carlos Sánchez")

    def test_summary_keeps_only_the_resumen_section(self) -> None:
        self.assertEqual(
            self.parsed["summary"],
            "Ajustes de carga laboral dominaron la sesión.\n\n"
            "**Gestión de Errores**\n"
            "El error crítico sigue sin resolverse.",
        )

    def test_extended_merges_details_and_next_steps_as_bullets(self) -> None:
        self.assertEqual(
            self.parsed["extended"],
            "## Detalles\n\n"
            "- **Carga Laboral**: Se discutió reducir la carga (00:00:00).\n"
            "- **Bugs**: Hugo toma el *bug* crítico (00:01:00).\n\n"
            "## Pasos siguientes recomendados\n\n"
            "- Hugo Anaya tomará el bug crítico.\n"
            "- Hugo Anaya actualizará el ticket diariamente.",
        )

    def test_transcript_excludes_the_notes_half(self) -> None:
        self.assertEqual(
            self.parsed["text"].split("\n"),
            [
                "00:00:00 Hugo Anaya: Hola a todos.",
                "00:00:43 Karim Darwich: Hola.",  # 60s block split by utterance length (13 : 5)
                "00:01:00 Hugo Anaya: Empecemos con los bugs.",
            ],
        )


if __name__ == "__main__":
    unittest.main()

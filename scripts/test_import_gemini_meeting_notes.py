#!/usr/bin/env python3
"""Tests for the Gemini meeting-notes export splitter.

The fixtures below use the **real** export flavor: every heading is bold (`## **…**`,
`### **HH:MM:SS**`) and markdown punctuation is backslash-escaped (`\\-`). Transcript *parsing*
is not tested here — the script hands the section to the app verbatim and
`TranscriptFileParser.parseGeminiNotes` (covered by `TranscriptFileParserTests`) owns it.
"""

from __future__ import annotations

import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from import_gemini_meeting_notes import count_turns, main, parse_export, parse_stamp

NOTES_HALF = """10 mar 2026

## **Llamada Semanal Dirección\\-TI**

Invitados [<span class="underline">Hugo Anaya</span>](mailto:hanaya@example.mx) \
[<span class="underline">Marco Rivadeneyra</span>](mailto:marco@example.mx) \
[~~<span class="underline">Juan Carlos Sánchez</span>~~](mailto:jsanchez@example.mx)

Archivos adjuntos [<span class="underline">Llamada Semanal</span>](https://www.google.com/calendar/event?eid=abc)

### **Resumen**

Ajustes de carga laboral dominaron la sesión.

**Gestión de Errores**
El error crítico sigue sin resolverse.

### **Detalles**

  - > **Carga Laboral**: Se discutió reducir la carga ([<span class="underline">00:00:00</span>](#section)).

  - > **Bugs**: Hugo toma el \\*bug\\* crítico ([<span class="underline">00:01:00</span>](#section-1)).

### **Pasos siguientes recomendados**

  - > Hugo Anaya tomará el bug crítico.

    > Hugo Anaya actualizará el ticket diariamente.

*Revisa las notas de Gemini para asegurarte de que sean correctas.* [*<span class="underline">Consejos</span>*](https://support.google.com/meet)

📖 Transcripción

10 mar 2026

"""

TRANSCRIPT_HALF = """## **Llamada Semanal Dirección\\-TI \\- Transcripción**

### **00:00:00**

\xa0
**Hugo Anaya:** Hola a todos.
**Karim Darwich:** Hola.


### **00:01:00**

**Hugo Anaya:** Empecemos con los bugs.

### **La transcripción finalizó después de 00:02:00**

*Esta transcripción editable se ha generado por ordenador y puede contener errores.*
"""

EXPORT = NOTES_HALF + TRANSCRIPT_HALF


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


class CountTurnsTests(unittest.TestCase):
    def test_counts_only_bold_speaker_turns(self) -> None:
        self.assertEqual(count_turns(TRANSCRIPT_HALF), 3)

    def test_a_section_with_no_turns_counts_zero(self) -> None:
        self.assertEqual(count_turns("## **X \\- Transcripción**\n\n### **00:00:00**\n"), 0)

    def test_a_bold_label_with_no_utterance_is_not_a_turn(self) -> None:
        self.assertEqual(count_turns("**Gestión de Errores:**\n**Ana:** sí"), 1)


class ParseExportTests(unittest.TestCase):
    def setUp(self) -> None:
        self.parsed = parse_export(
            EXPORT,
            "Llamada_Semanal_Direccio_nTI__2026_03_10_11_00_CST__Notas_de_Gemini.md",
            self_email="marco@example.mx",
        )

    def test_title_comes_from_the_bold_document_heading_not_the_filename(self) -> None:
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

    def test_summary_keeps_only_the_bold_resumen_section(self) -> None:
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

    def test_transcript_section_is_handed_over_verbatim(self) -> None:
        # The app's own parser owns this text; the script must not rewrite it. The banner stays in
        # because it is one of the two signals TranscriptFileParser uses to detect the format.
        self.assertEqual(self.parsed["text"], TRANSCRIPT_HALF.strip())

    def test_transcript_excludes_the_notes_half(self) -> None:
        self.assertNotIn("Resumen", self.parsed["text"])
        self.assertNotIn("Ajustes de carga laboral", self.parsed["text"])
        self.assertNotIn("📖", self.parsed["text"])


class TranscriptOnlyExportTests(unittest.TestCase):
    """Real exports are often transcript-only: a date line and the transcript half, no notes."""

    def setUp(self) -> None:
        self.parsed = parse_export(
            "jul 22, 2026\n\n" + TRANSCRIPT_HALF,
            "Llamada Semanal - 2026_03_10 11_00 CST - Notas de Gemini.md",
        )

    def test_title_falls_back_to_the_transcript_banner(self) -> None:
        self.assertEqual(self.parsed["title"], "Llamada Semanal Dirección-TI")

    def test_transcript_is_still_extracted(self) -> None:
        self.assertEqual(count_turns(self.parsed["text"]), 3)

    def test_notes_fields_are_empty(self) -> None:
        self.assertEqual(self.parsed["summary"], "")
        self.assertEqual(self.parsed["extended"], "")


class NoTranscriptTests(unittest.TestCase):
    def test_a_notes_only_export_yields_no_transcript(self) -> None:
        parsed = parse_export(NOTES_HALF, "x__2026_03_10_11_00_CST.md")
        self.assertEqual(parsed["text"], "")
        self.assertEqual(parsed["summary"].splitlines()[0], "Ajustes de carga laboral dominaron la sesión.")


class MainTests(unittest.TestCase):
    """End-to-end CLI behavior: `--dry-run` reports, an export with no turns is skipped."""

    def _run(self, contents: str, name: str, *extra: str) -> tuple[int, str, str]:
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, name)
            Path(path).write_text(contents, encoding="utf-8")
            out, err = io.StringIO(), io.StringIO()
            with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                status = main([path, "--dry-run", *extra])
            return status, out.getvalue(), err.getvalue()

    def test_dry_run_reports_the_parsed_export_and_succeeds(self) -> None:
        status, out, err = self._run(
            EXPORT, "Llamada Semanal - 2026_03_10 11_00 CST - Notas de Gemini.md"
        )
        self.assertEqual(status, 0, err)
        self.assertIn("DRY  Llamada Semanal Dirección-TI @ 2026-03-10T11:00:00-06:00", out)
        self.assertIn("3 turns, 2 attendees", out)

    def test_dry_run_imports_a_transcript_only_export(self) -> None:
        status, out, _ = self._run(
            "jul 22, 2026\n\n" + TRANSCRIPT_HALF,
            "Llamada Semanal - 2026_03_10 11_00 CST - Notas de Gemini.md",
        )
        self.assertEqual(status, 0)
        self.assertIn("3 turns", out)

    def test_an_export_with_no_turns_is_skipped_and_fails(self) -> None:
        status, out, err = self._run(NOTES_HALF, "Notas - 2026_03_10 11_00 CST.md")
        self.assertEqual(status, 1)
        self.assertEqual(out, "")
        self.assertIn("no transcript turns found", err)

    def test_a_missing_file_is_skipped_and_fails(self) -> None:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            status = main(["/nonexistent/path/to/export.md", "--dry-run"])
        self.assertEqual(status, 1)
        self.assertIn("SKIP", err.getvalue())


if __name__ == "__main__":
    unittest.main()

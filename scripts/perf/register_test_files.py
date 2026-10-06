#!/usr/bin/env python3
"""Register the perf benchmark files in an exported tree's TypeWhisperTests target.

Usage: register_test_files.py <path/to/project.pbxproj>

Used only on the pre-refactor export (772f3535), whose project does not list the benchmark
files. Anchors on ObsidianVaultServiceTests.swift, which exists at both commits. Idempotent.
"""
import sys

FILES = [
    ("PerfBenchmarkTests.swift", "PF2D00000000000000000032", "PF2D00000000000000000033"),
    ("PerfBenchmarkFixtures.swift", "PF2D00000000000000000034", "PF2D00000000000000000035"),
    ("PerfBenchmarkShim.swift", "PF2D00000000000000000036", "PF2D00000000000000000037"),
]
ANCHORS = (
    "MEB0000000000000000008 /* ObsidianVaultServiceTests.swift in Sources */ = {",
    "MEF0000000000000000008 /* ObsidianVaultServiceTests.swift */ = {",
    "\t\t\t\tMEF0000000000000000008 /* ObsidianVaultServiceTests.swift */,",
    "\t\t\t\tMEB0000000000000000008 /* ObsidianVaultServiceTests.swift in Sources */,",
)

def main(path: str) -> None:
    text = open(path, encoding="utf-8").read()
    for name, build_id, ref_id in FILES:
        if build_id in text:
            continue
        additions = (
            f"\t\t{build_id} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref_id} /* {name} */; }};\n",
            f"\t\t{ref_id} /* {name} */ = {{isa = PBXFileReference; includeInIndex = 1; "
            f"lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};\n",
            f"\t\t\t\t{ref_id} /* {name} */,\n",
            f"\t\t\t\t{build_id} /* {name} in Sources */,\n",
        )
        for anchor, addition in zip(ANCHORS, additions):
            lines = [line for line in text.split("\n") if anchor in line]
            if len(lines) != 1:
                sys.exit(f"anchor not found exactly once: {anchor!r}")
            full = lines[0] + "\n"
            text = text.replace(full, full + addition)
    open(path, "w", encoding="utf-8").write(text)

if __name__ == "__main__":
    main(sys.argv[1])

# PLACEHOLDER APP ICON — must be replaced before any public/shipping build

These 10 PNGs are a **temporary, brand-neutral placeholder** generated for the MeetingWhisper fork.
Upstream TypeWhisper's original artwork is **trademark-restricted** and was intentionally removed;
do not reuse it.

- Motif: flat calendar + audio waveform on an indigo squircle (meetings + speech).
- Generated deterministically by [`scripts/generate-placeholder-icon.swift`](../../../../scripts/generate-placeholder-icon.swift)
  using only CoreGraphics + ImageIO (no third-party deps).

## Regenerate

```bash
swift scripts/generate-placeholder-icon.swift
```

Re-running overwrites all 10 PNGs in place (fixed colors + geometry). `Contents.json` is unchanged.

## Owner action item

Commission / design a final icon and replace these files (or point the generator at the real
artwork export) before publishing any release build.

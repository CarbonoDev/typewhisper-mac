# site/

The Meeting Whisper landing page. One self-contained file — `index.html` — with no build step,
no dependencies, and no external requests (fonts are the macOS system stack, the favicon is an
inline SVG data URI, the waveforms are generated in a few lines of vanilla JS).

## Preview

```bash
python3 -m http.server 8931 --directory site
# → http://127.0.0.1:8931
```

## Deploy

Any static host works, since the folder is already the built output:

- **GitHub Pages** — Settings → Pages → deploy from branch, folder `/site`.
- **Vercel / Netlify / Cloudflare Pages** — set the publish directory to `site`, leave the build
  command empty.

## Design notes

The page deliberately reuses the app's own design language rather than inventing a second one.
The tokens at the top of `index.html` are carried over from
[`TypeWhisper/Views/Meetings/MeetingTheme.swift`](../TypeWhisper/Views/Meetings/MeetingTheme.swift):

| Page token | Comes from |
|---|---|
| `--paper` `#FBFAF7` | `MeetingTheme.paperBackground` — the meeting document's warm reading ground |
| `--accent` | `MeetingTheme.avatarPalette[0]`, indigo, darkened for text contrast on paper |
| `--live` | `avatarPalette[1]`, sienna — reserved for recording state only |
| `--av-*` | the attendee-initial hues, used on the example document's faces |
| `--measure` `40rem` | `MeetingTheme.contentMaxWidth` (640) |
| serif display | matches SwiftUI's `design: .serif` (New York) used for meeting titles |
| uppercase kicker / section labels | `MeetingTheme.kicker` / `.sectionLabel`, including the tracking |

If those tokens change in the app, change them here too.

Both light and dark are defined token-level in three blocks — bare `:root`, then
`@media (prefers-color-scheme: dark)` guarded with `:root:not([data-theme="light"])`, then
`:root[data-theme="dark"]` — so the page renders correctly whether or not the host stamps a theme
onto the root element. No color is declared outside that token set.

## Copy accuracy

Every claim on the page maps to something the app actually does today (see the root `README.md`).
The primary CTA is the GitHub repository and the build instructions, because there is no signed
release — the page says so plainly rather than implying a download exists. The footer credits
upstream TypeWhisper, states GPLv3, and flags that the name is a working title.

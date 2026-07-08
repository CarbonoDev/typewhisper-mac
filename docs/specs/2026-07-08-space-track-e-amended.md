# Space (Track E) — Amended Vault-Browser Spec

Status: authoritative in-repo target for Track E. **Do not build in M5** — this is the written
target Track E implements later. Reconciles the base Meetings language/tags/folders plan (§4, D10)
with Amendment 1 (folder detail view + vault context picker + scoped retrieval) and Amendment 2
(agentic related-document discovery). Written as the final deliverable of milestone M5.

## 1. Summary

**Space is the read-write browser for the Obsidian vault on disk.** It lives in the sidebar's
already-reserved `spaceSection` slot, below the first-party Folders and Tags sections, and routes
through the reserved `MainWindowRoute.spaceFolder(String)` / `.spaceNote(String)` cases. It is a
*projection* of the vault; it never owns meeting organization.

The clean division of responsibility Track E must preserve:

- **First-party Folders / Tags (top of sidebar, this feature) own meeting organization.** They
  filter the in-app meetings list, work with **no vault connected**, and are backed by the meeting
  store (`obsidianFolder` / `obsidianTags`), not the vault.
- **Space (lower sidebar, Track E) browses the vault.** Open notes, quick-note, atomic
  never-clobber writes. It is **gated on a connected vault**.

These are complementary, not competing: the same folder hierarchy renders in both places, by
construction, because of the uniform export layout below.

## 2. Non-negotiable invariants Track E inherits

1. **The shell is frozen.** Track E never edits `MainWindowRoute`, `MainWindowCoordinator`, or the
   sidebar's Home/Meetings/Folders/Tags structure. It fills the reserved `spaceSection` slot and the
   reserved `spaceFolder`/`spaceNote` routes — nothing else. Route families stay disjoint forever:
   `.folder`/`.tag` = in-app data; `.spaceFolder`/`.spaceNote` = vault.
2. **Meetings emit no events in v1.** Space observes no meeting EventBus signal; it reads the vault
   and the meeting store directly, same as every other meetings surface.
3. **Space is gated on a connected vault; Folders/Tags are not.** With no vault connected, the
   Space section is absent (or an inert "connect a vault" affordance), while Folders/Tags keep
   working.

## 3. One vault enumerator — the single most important reconciliation

There is **exactly one vault scanner** in the app, and Space reuses it. Amendment 1 (DA8) already
introduced the read-only listing primitives on `ObsidianVaultService`, and Amendment 2 (DB) reuses
them for discovery. Track E consumes the **same** primitives — it never adds a second scanner:

- `enumerateNotes()` — the full parse (title + tags + body), used by retrieval ranking.
- `listEntries() -> [VaultEntry]` — notes **and** folders, path + display name, **no body parse**
  (cheaper). This is the foundation of Space's file/folder tree.
- `searchEntries(_ query:limit:) -> [VaultEntry]` — case-insensitive over path + title.
- `candidateNotes(query:limit:excluding:)` (Amendment 2) — ranked wider-vault candidates for the
  discovery judge; still the same enumerator underneath.

Consequences for Track E:

- **The M7 vault context picker (`VaultContextPickerView`) and Space share these primitives.** They
  differ only in *interaction*, never in *data source*:
  - the picker is a **modal selector** — search, multi-select paths, confirm; it writes selected
    paths into a folder's `FolderContextConfig` (or a meeting's related set in Amendment 2);
  - Space is the **full read-write browser** — open a note, create a quick-note, write atomically
    (never-clobber, matching the exporter's `uniquePath` discipline).
  Neither reimplements the other.
- **The relevance judge is a meeting-scoped LLM concern, never a Space feature.** Amendment 2's
  discovery judge (`MeetingRelatedDocsService`) is one `process()` call that ranks vault candidates
  for a *meeting*. Space stays a browser: **Space never gains a judge.** Discovery merely *reads*
  the vault through the shared enumerator; the judgment lives with the meeting.

## 4. Shared layout — the trees align 1:1 by construction

Export folder resolution is uniform (base plan D7): a meeting's note lands at
`vaultRoot / <meetingsObsidianRootFolder> / <sanitized folderPath components>`, with **no
grandfathering** (the migration relocates every meeting's *next* export under the root; old notes
are left untouched by the never-overwrite `uniquePath` rule).

Because the layout is uniform:

- A first-party folder `Clients/Acme` exports under `<root>/Clients/Acme`, so the first-party
  folder tree and Space's vault tree render the **same** hierarchy node — there is never a "which
  Acme?" ambiguity.
- A folder's attached vault-folder path (Amendment 1) and a discovered note path (Amendment 2)
  resolve to the **same** Space node they would under the vault browser. Attachments, discovery,
  and Space all point at one hierarchy.

Track E must therefore **enumerate vault folders under `meetingsObsidianRootFolder + folderPath`**
and must **not** invent a parallel "meeting folders" framing — the first-party tree is the source
of meaning; Space is its on-disk projection.

## 5. Cross-links via the `typewhisper-meeting` backlink

Export frontmatter carries `typewhisper-meeting: <uuid>`. Track E uses it both directions as the
bridge between the vault projection and in-app meetings:

- **From a Space note → the meeting:** "Open meeting" resolves the frontmatter uuid to
  `MainWindowCoordinator.openMeeting(id:)` (`.meeting(uuid)`).
- **From a meeting → Space:** the meeting document surfaces "Reveal in Space" when
  `lastObsidianExportAt != nil` (the meeting has been exported at least once).

Optional, later, not required for the first Space build: Space *may* offer "Attach to folder
context" and the picker *may* offer "Browse in Space" — but the picker stays a selector and Space
stays the browser.

## 6. Copy / framing rules

- Space's header and copy are **vault browsing** ("Space — Obsidian vault"), never "meeting
  folders." First-party Folders/Tags own meeting organization; Space's copy is explicitly a
  projection of the vault on disk.
- The folder **detail view**'s Context section (Amendment 1, DA7) stays the *folder-level* attached
  scope; Amendment 2's per-meeting Related Documents section stays the *meeting-level* tier. Space
  is a third, orthogonal surface (the raw vault) — it does not absorb either.
- When no vault is connected, Space is inert ("connect a vault"); the folder detail view's Context
  section is likewise inert; Folders/Tags stay fully functional.

## 7. Checklist for whoever builds Track E

- [ ] Fill the reserved `spaceSection` slot; fill the reserved `.spaceFolder`/`.spaceNote` routes.
      Touch nothing else in the shell.
- [ ] Build the tree from `listEntries()` / `searchEntries()` — the existing enumerator. No second
      vault scanner.
- [ ] Enumerate under `meetingsObsidianRootFolder + folderPath`; render the same hierarchy as the
      first-party folder tree.
- [ ] Reuse `typewhisper-meeting` for both-direction links; gate "Reveal in Space" on
      `lastObsidianExportAt != nil`.
- [ ] Keep Space a read-write browser (atomic never-clobber writes). No relevance judge, no
      meeting-organization ownership.
- [ ] Gate the whole section on a connected vault.

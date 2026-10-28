# ClipDesk architecture

ClipDesk is a Swift package with three targets:

| Target | Kind | Responsibility |
|---|---|---|
| `ClipDeskCore` | library | Clipboard engine, classification, SQLite persistence, payload files, settings. No SwiftUI. All unit and integration tests target this module. |
| `ClipDeskUI` | library | SwiftUI/AppKit presentation: scenes, history window, Menu Bar popover, Settings, app coordinator. |
| `ClipDesk` | executable | `main.swift` only; calls `ClipDeskApp.main()`. |

```
Sources/ClipDeskCore
  Domain/      ClipEntry, ClipFile, ContentKind, HistoryCategory, RetentionPolicy
  Clipboard/   PasteboardSnapshot, PasteboardReader, ClipboardMonitor, PasteboardWriter,
               ContentClassifier, ImageInspector
  Storage/     HistoryStore (actor), SQLiteDatabase, Schema (migrations), PayloadStore
  Services/    CapturePreparer (hashing, dedupe keys, search text), AppSettings
Sources/ClipDeskUI
  App/         ClipDeskApp (scenes, AppDelegate, activation policy, menu commands), AppModel,
               DebugSnapshots (DEBUG builds only)
  Features/    History/, MenuBar/, Settings/
  Shared/      Theme, shared components
```

## Data model

- **Entry** (`ClipEntry`): one clipboard operation. It has a kind, a screenshot flag, title, preview text, first-copied and last-activity times, use count, favorite flag, size, source app and metadata (text statistics, image size, omitted formats).
- **Item** (`PasteboardSnapshot.Item`): one `NSPasteboardItem` within the operation. Multi-item copies (several files, several text items) stay together in one entry.
- **Representation**: one type identifier plus its bytes, for example `public.utf8-plain-text`, `public.rtf` and `public.html` for the same item. All are stored, in the source app's order.
- **File** (`ClipFile`): a referenced file. It records the original path, name, type, size and modification date, an optional managed-copy path, a storage state (`copied`, `tooLarge`, `directory`, `unreadable`, `copyingDisabled`, `missing`), and an availability computed at load time (`original`, `storedCopy`, `unavailable`).

## Capture lifecycle

1. **Poll.** `ClipboardMonitor` runs a `DispatchSourceTimer` on a utility-QoS serial queue (default 0.5 s, 100 ms leeway). It compares `NSPasteboard.changeCount` with the last value it saw, which is a cheap call. Nothing else happens until the count changes.
2. **Filter.** `PasteboardReader` returns `.skipped` for:
   - an empty pasteboard;
   - ClipDesk's own writes (a marker type on restored items, plus the exact `changeCount` that `PasteboardWriter` reported);
   - content carrying concealed/transient markers.
3. **Read.** It reads representations in priority order (plain text, URL, RTF, HTML, PNG, JPEG, TIFF, then everything else) within a per-capture byte budget. Unknown types are capped at 2 MB. File promises are never read. For Finder file copies only the file URL and name are kept. Redundant TIFF next to PNG, and synthesized UTF‑16 text next to UTF‑8, are dropped. The result is an immutable, `Sendable` `PasteboardSnapshot`.
4. **Classify.** `ContentClassifier` decides the kind in priority order: files → text (link / code / text) → image (screenshot if the EXIF comment says so) → other.
5. **Prepare.** `CapturePreparer` computes:
   - text statistics;
   - a **dedupe key**: identity of the content. This is the plain text for textual items, the primary image bytes for images, and the ordered file paths for files;
   - a **content hash** over every representation, plus file sizes and dates;
   - folded (case/diacritic-insensitive) search text.
6. **Store.** `HistoryStore.ingest` (an actor, off the main thread):
   - **Same dedupe key and same hash:** update `last_used_at` and `use_count` only. No disk I/O for payloads.
   - **Same key, different hash:** write new payloads to a fresh directory, replace the entry's rows in a transaction (keeping id, first-copied date and favorite), then delete the old directory.
   - **New content:** write payloads, insert rows in a transaction. If anything fails, the new payload directory is removed.
   - Retention runs afterwards.
7. **Present.** `AppModel` bumps a revision counter. Visible views reload through `.task(id:)`: the list, sidebar counts and the popover.

### Restoring

`HistoryStore.restorePayload` rebuilds the original items and representations. For file entries it substitutes the managed copy when the original is gone, and returns warnings for files that are unavailable. `PasteboardWriter` (main actor) writes one `NSPasteboardItem` per stored item and adds the ClipDesk marker type. `AppModel` then tells the monitor to ignore the resulting `changeCount` and marks the entry as used, which moves it to the top.

## Persistence

- **Database:** `~/Library/Application Support/ClipDesk/history.sqlite`, accessed through the system SQLite C API with parameterized statements only. Settings: WAL, `synchronous=NORMAL`, foreign keys with `ON DELETE CASCADE`, `secure_delete=ON`.
- **Tables:**
  - `entries`: metadata, `search_text`, `dedupe_key` (unique), `content_hash`, `payload_dir`, metadata JSON;
  - `representations`: inline BLOB for data ≤ 64 KB, otherwise a payload file path;
  - `files`: file references and storage state.
- **Migrations:** ordered SQL migrations, each applied in its own transaction. `PRAGMA user_version` records the schema version. A database from a newer ClipDesk version is rejected rather than modified.
- **Corruption:** `PRAGMA quick_check` runs at launch. A damaged database is renamed to `history-damaged-<timestamp>.sqlite` and a new one is created, and the user is told.
- **Payloads:** each capture owns one directory, `Payloads/<uuid>/`, holding large representations (`r<item>-<position>.bin`), managed file copies (`files/<n>/<original name>`) and `thumbnail.png` (at most 192 px, generated once with ImageIO). Deleting an entry deletes exactly that directory. `PayloadStore` refuses to delete anything that is not a direct `Payloads/<uuid>` child. Directories no row references are removed at launch.
- **Search:** each whitespace-separated term must match (`LIKE … ESCAPE`) the folded search text. Folding is case-, diacritic- and width-insensitive, and the search text includes title, up to 200,000 characters of text, file paths and source app. Images and binary data are not indexed.

## Concurrency

The package builds in Swift 6 language mode with strict concurrency checking.

- `HistoryStore` is an actor that owns the SQLite connection.
- `ClipboardMonitor` confines its state to its own serial queue.
- UI state (`AppModel`, `HistoryQuery`, `AppSettings`) is `@MainActor @Observable`.
- Image decoding for thumbnails and previews runs in detached tasks and uses ImageIO downsampling, so full-size bitmaps are never decoded for list rows.

## Windows and activation

ClipDesk is an agent app (`LSUIElement`), so it has no Dock icon by default. `ActivationPolicyController` switches it to a regular app (Dock icon and menu bar) while the history or Settings window is open, and back to accessory when they close. Closing the last window does not quit the app. Quit is available from the popover and the app menu.

## Development hooks

These environment variables exist for development and automated checks:

| Variable | Effect |
|---|---|
| `CLIPDESK_DATA_DIR` | Use a different data directory. |
| `CLIPDESK_DEFAULTS_SUITE` | Use a separate `UserDefaults` suite. |
| `CLIPDESK_PASTEBOARD_NAME` | Monitor and restore to a private named pasteboard instead of the general clipboard. |
| `CLIPDESK_DEBUG_SNAPSHOT_DIR` | **Debug builds only** (`DebugSnapshots` is compiled out of Release). Walks through representative UI states and renders ClipDesk's own windows to PNG with `NSView.cacheDisplay`. It also runs two app-level checks: copy-back without duplication, and pause/resume. |

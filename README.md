# Navigator

A premium, Finder-style file manager for macOS — built for a Windows → Mac switcher who wants the power of Windows 11 File Explorer with native Mac polish. Written in Swift (SwiftUI + AppKit) as a single file (`main.swift`), compiled with `swiftc` — no Xcode project required.

![Navigator icon](AppIcon.png)

## Requirements
- **Apple Silicon or Intel Mac** — the release is a **universal** binary
- **macOS 14 (Sonoma) or newer**

## Download (no build required)
Grab the latest **Navigator.zip** from the [**Releases**](../../releases/latest) page:
1. Unzip it and drag **Navigator.app** into **Applications**.
2. **First launch (one-time):** right-click (Control-click) **Navigator.app → Open → Open**.

> Navigator isn't notarized by Apple, so a plain double-click shows a security warning the first time. Right-click → Open gets past it once; afterward it opens normally. (Alternatives: **System Settings → Privacy & Security → Open Anyway**, or `xattr -dr com.apple.quarantine /Applications/Navigator.app`.)

## Build from source
Needs the **Xcode Command Line Tools** (`xcode-select --install`). One command builds, signs, and installs to `/Applications`:

```bash
git clone <your-repo-url> NavigatorApp
cd NavigatorApp
bash rebuild.sh
open /Applications/Navigator.app
```

- `rebuild.sh` compiles `main.swift`, generates the icon from `AppIcon.png`, assembles the `.app` bundle, and code-signs it.
- `quickbuild.sh` is a faster variant for iterating (skips icon regeneration).

### Stable code signing (recommended, optional)
If a self-signed **“Navigator Dev”** certificate exists in your login keychain, `rebuild.sh` signs with it so the app's identity stays constant across rebuilds — which means macOS **remembers** its Full Disk Access / folder-access grants instead of re-prompting every build. Without it, the build falls back to ad-hoc signing (still runs; permissions just reset per build). A backup of the cert lives in `~/.navigator-signing/` (password in its README).

### Sharing with someone else
Send them the [Releases](../../releases/latest) download (universal, runs on Apple Silicon and Intel, macOS 14+). Because it isn't notarized, the first launch needs a one-time **right-click → Open**. Truly zero-warning distribution would require Apple Developer ID signing + notarization ($99/yr Apple Developer Program).

## Features

**Views** — List, Icon, Gallery (big preview + filmstrip), and Column (Miller) views. The left **sidebar is an expandable tree** (Windows-11-style): click a folder's disclosure triangle to drill into subfolders inline.

**Navigation** — Editable address bar (⌘L), clickable breadcrumb, tabs (⌘T/⌘W), multiple windows (⌘N), back/forward/up, full keyboard navigation (arrows, Return to open, Backspace for enclosing folder), and type-to-select. Reopens your tabs and window position on launch.

**Dual pane** — Split the content into two independent panes (⌥⌘2) to drag files between them, ForkLift-style.

**File operations** — Copy / Cut / Paste / Duplicate / Rename / Move to Trash / Empty Trash / Compress / **Extract** (zip + tar family) / **Batch rename** (find-replace, prefix/suffix, numbering) / New Folder / New Text File / Make Alias / **Make Symbolic Link**. Copy/move show a **progress window** and a **conflict dialog** (Keep Both / Replace / Skip). Most operations are **undoable** (⌘Z).

**Metadata & columns** — Toggle columns from the header menu: Name, Date Modified/Created/Added, Size (with on-demand **folder size** calculation), Kind, Extension, and — read lazily from Spotlight — media **Duration**, image/video **Dimensions**, and **Tags**. Column widths and choices persist.

**Preview & Get Info** — A toggleable preview pane (⇧⌘P) and a rich **Get Info** window with editable name, tags, comments, permissions, and Open With. **Set/edit Finder tags** (colored) and comments.

**Search** — Instant name **filter** for the current folder, plus a recursive **Spotlight search** with scope (This Folder / This Mac) and kind filters (Images / Documents / PDFs / Movies / Audio / Folders).

**Sidebar** — Customizable **Favorites** (drag a folder in, or “Add to Sidebar”), **Recents** and **Recent Folders**, **Cloud** (iCloud / Google Drive / OneDrive / Dropbox), **Locations** (disks — USB/external drives auto-appear on plug-in, with eject), **Network** (Bonjour-discovered SMB servers), and **Connect to Server** (⌘K).

**System integration** — Appears in Finder's **Open With** for folders; an **“Open in Navigator”** entry in Finder's Services menu; **Open With / set default app** for files; **Open in Terminal**; **Quick Look** (Space / ⌘Y); **Share…**; built-in **image viewer** (←/→ through a folder). Status bar shows item count and free space.

**Extras** — Grant Full Disk Access helper, Set as Default File Browser helper (with an honest explanation of macOS's Finder restriction), and light/dark theme following the system.

## Keyboard shortcuts
| Shortcut | Action |
|---|---|
| ⌘L / ⌘F | Focus address bar / search |
| ⌘T / ⌘W / ⌘N | New tab / close tab / new window |
| ⇧⌘N / ⌥⌘N | New folder / new text file |
| ⌘I / ⌘D / ⌘Y or Space | Get Info / Duplicate / Quick Look |
| ⌘⌫ / ⇧⌘⌫ | Move to Trash / Empty Trash |
| ⌘[ / ⌘] / ⌘↑ | Back / Forward / Enclosing folder |
| ⇧⌘P / ⌥⌘S / ⌥⌘2 | Toggle preview / sidebar / dual pane |
| ⇧⌘. / ⌘R / ⌘Z / ⌘K | Show hidden / Refresh / Undo / Connect to Server |

## Known limitations
- **Cannot fully replace Finder** as the system folder handler — macOS locks that to Finder. Navigator registers as a folder app instead (Open With, the Services entry, and `open -b com.merickson.navigator <folder>` all work).
- **Empty Trash** clears only the home volume's `~/.Trash`, not per-volume trashes.
- **Bonjour** network discovery needs macOS's Local Network permission; unmounted servers may not appear until it's granted.
- Favorites are added/removed via drag and context menu (drag-to-reorder was removed when the sidebar became an expandable tree).
- The app-icon source is 616×616, so the largest (1024) icon size is slightly upscaled.

## License
Personal project. No warranty.

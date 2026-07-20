# Navigator

A lightweight, Finder-style file manager for macOS, written in Swift (SwiftUI + AppKit), built for a Windows→Mac switcher. Single-file app (`main.swift`), compiled with `swiftc` — no Xcode project required.

## Features
- Editable **address bar** (⌘L, type a path, Return) + clickable breadcrumb
- **Tabs** (⌘T / ⌘W, drop a file on a tab to move it there)
- **List** and **Icon** views, with image **thumbnails** and an icon-size **zoom** slider
- **Copy / Cut / Paste / Duplicate / Rename / Compress / Move to Trash / Empty Trash** (follows system keyboard shortcuts)
- **Get Info**, **Make Alias**, **Share…**, **Open in Terminal**, **Quick Look** (⌘Y)
- **Recents** (Spotlight-backed), **Cloud** (Google Drive / iCloud / OneDrive / Dropbox), **Locations** (disks + network), **Connect to Server** (⌘K)
- Built-in **image viewer** with ←/→ scrolling through a folder's images
- **Full Disk Access** helper (Navigator menu → Grant Full Disk Access…)

## Build & run
```bash
bash rebuild.sh      # compiles main.swift, builds the icon, installs to /Applications/Navigator.app
open /Applications/Navigator.app
```
Requires the Xcode Command Line Tools (`swiftc`). Target: macOS 14+.

## Known issues / needs testing
These are the areas most likely to be buggy — help wanted:

- **Quick Look (⌘Y)** — opens a QLPreviewPanel via a data source only; without a full responder-chain controller it may show blank. Likely needs the standard `QLPreviewPanelController` responder wiring.
- **Multi-item drag** — rows/icons use per-item `.draggable`, so dragging a multi-selection probably only carries one item.
- **⌘C / ⌘X on files** — routed through the app-delegate as a responder-chain fallback; may not fire depending on focus (Paste is verified working).
- **Drag onto the sidebar / onto a folder row** — not implemented (per-row drop was removed because it blocked double-click-to-open).
- **Spring-loaded folders/tabs** — hovering during a drag does not yet open a folder or switch tabs.
- **Empty Trash** — only empties the home volume's `~/.Trash`, not per-volume trashes.
- **Get Info** — shows "Folder" instead of a computed folder size.
- **Filter box** — filters the current folder by name only; not a recursive/content search.
- **Share…** — the share sheet may anchor to the window origin rather than the selection.

The long-term fix for solid drag-and-drop + spring-loading is rebuilding the file list on AppKit `NSTableView`/`NSCollectionView` (SwiftUI's `Table` can't reliably start row drags while also handling double-click).

## License
Personal project. No warranty.

# Navigator

A premium, Finder-style file manager for macOS — built for a Windows → Mac switcher who wants the power of Windows 11 File Explorer with native Mac polish. Written in Swift (SwiftUI + AppKit) as a single file (`main.swift`), compiled with `swiftc` — no Xcode project required.

![Navigator icon](AppIcon.png)

## Requirements
- **Apple Silicon or Intel Mac** — the release is a **universal** binary
- **macOS 14 (Sonoma) or newer**

## Install (no build required)

1. Download the latest **Navigator.zip** from the [**Releases**](../../releases/latest) page.
2. Unzip it and drag **Navigator.app** into your **Applications** folder.
3. Do the one-time first-launch step below, then grant permissions.

---

## First launch & permissions

Navigator is signed with a **self-signed** certificate (not an Apple Developer ID), so macOS treats it as an app "from an unidentified developer." A few one-time steps get it fully working. None of this recurs after the first time.

### 1. Open it the first time (get past Gatekeeper)
A plain double-click will be blocked the first time. Instead, do **one** of:
- **Right-click (Control-click) Navigator.app → Open → Open.** ← easiest
- **System Settings → Privacy & Security**, scroll to *"Navigator was blocked…"* → **Open Anyway**.
- Terminal: `xattr -dr com.apple.quarantine /Applications/Navigator.app`

After this once, it launches normally every time.

### 2. Allow folder-access prompts (Desktop / Documents / Downloads)
The first time Navigator opens your **Desktop**, **Documents**, or **Downloads**, macOS asks *"Navigator would like to access files in your … folder."* Click **OK / Allow**.
- Clicked *Don't Allow* by mistake? Re-enable it in **System Settings → Privacy & Security → Files and Folders → Navigator**.

### 3. Grant Full Disk Access (recommended)
For **full** functionality — moving items in protected folders (Pictures, Documents, Desktop, Downloads) to the Trash, copying/renaming there, and browsing system locations without repeated prompts — give Navigator **Full Disk Access**:

- **From Navigator:** menu bar → **Navigator → "Grant Full Disk Access…"** (opens the correct settings pane), **or**
- **Manually:** System Settings → **Privacy & Security → Full Disk Access** → click **+** → select **Navigator** from Applications → toggle it **on** → **relaunch Navigator**.

Without this, operations on protected folders may fail — Navigator will tell you exactly what failed and why (it no longer fails silently), and point you here.

### 4. Local Network (for discovering servers)
To auto-discover SMB file servers on your LAN (the **Network** section of the sidebar, via Bonjour), allow the **Local Network** prompt on first launch — or enable it later in **System Settings → Privacy & Security → Local Network → Navigator**.

### 5. Connecting to network drives / servers
Use **Connect to Server (⌘K)** or the Dock-icon menu to mount an SMB/AFP share (e.g. `smb://server/share`). You must be on the same network (or VPN) as the server. Mounted shares appear under **Locations**. Navigator applies a safe per-user SMB tuning automatically on launch for smoother network browsing.

### Sharing a set of drives with a team
The app ships with **no** preconfigured network drives — a fresh install is a clean local file explorer. To hand a team the same shortcuts:
- On a configured Mac: **File → Export Favorites…** → save the `.json` (personal home folders are left out; network drives are included).
- Each coworker: **File → Import Favorites…** → pick that file. The drives appear in their sidebar, and they connect through **their own** VPN and login the first time they click one.

No company server names are baked into the app, so the same public build works for everyone; the shared `.json` lives wherever your team shares files (Slack/Drive).

---

## Updating
Navigator updates itself from this repo's Releases — **your settings and permissions are never touched** (they live in `~/Library`, not in the app bundle, and the signing identity stays stable).

- **Automatic:** on launch (at most once a day) Navigator quietly checks for a newer release and, if there is one, asks whether to update.
- **Manual:** **Navigator menu → "Check for Updates…"**.

When you choose **Update Now**, it downloads the new `Navigator.zip`, replaces the app in `/Applications`, and relaunches — favorites, view settings, pinned drives, and Full Disk Access all carry over. (If `/Applications` isn't writable, it points you to the Releases page to update manually.)

> **Why the grants stick:** macOS ties these permissions to the app's code signature. The release build has a **stable** signature, so your grants persist across updates — you won't have to re-grant them each time you install a new version.

---

## Features

**Windows 11-style command bar** — A full-width top bar: **New ▾ · Cut · Copy · Paste · Rename · Share · Delete · Sort ▾ · View ▾ · ⋯ · Details**, above the navigation / file / details panes. **⌘ + scroll wheel** resizes and cycles the view (Details → Columns → Icons, with smooth icon sizing), just like Explorer's Ctrl+scroll.

**Views** — List (Details), Icon (small→extra-large), Gallery (big preview + filmstrip), and Column (Miller) views. The **sidebar is an expandable tree**: click a folder's disclosure triangle to drill in inline.

**Thumbnails** — Real thumbnails in every view for images, **video** (poster frame), **PSD/PSB**, **PDF**, and **RAW** — via QuickLook. **Animated GIFs play** in the viewer and preview pane.

**Image viewer** — Built-in viewer with **zoom** (scroll wheel, ⌘+/−/0, and a zoom slider), drag-to-pan, ←/→ through the folder, and a bottom bar showing **dimensions, file size, and position**.

**Pin folders (Quick Access)** — Right-click any folder → **Pin to Sidebar**; pinned favorites show a **pushpin** you can click to unpin. **Drag to reorder** favorites; Home stays a fixed anchor at the top.

**Settings (⌘,)** — **Navigator → Settings…**: default view and sort for new windows, show hidden files by default, confirm-before-Trash, and a **Thumbnails** control (All / Images only / Off) — turn thumbnails down or off for maximum speed on slow network drives.

**Navigation** — Editable address bar (⌘L), clickable breadcrumb, tabs (⌘T/⌘W), multiple windows (⌘N), back/forward/up, full keyboard nav, and type-to-select. Reopens your tabs and window position on launch. **Auto-refresh**: the current folder updates automatically when files change on disk (local & cloud folders, via FSEvents).

**Selection** — Click to select, **⇧-click** for a range, **⌘-click** to toggle individual items, and **drag a rubber-band** over empty space to select many at once — in every view (List, Icon, Column, Gallery).

**File operations** — Copy / Cut / Paste (**⌘C/⌘X/⌘V**, with numbered-copy paste-in-place) / Duplicate / Rename / Move to Trash / Empty Trash / Compress / **Extract** (zip + tar) / **Batch rename** / New Folder / New Text File / Make Alias / **Make Symbolic Link**. Copy/move show a **progress window** and **conflict dialog** (Keep Both / Replace / Skip). Most operations are **undoable** (⌘Z), and failures are always reported — never silent.

**Dual pane** — Split into two independent panes (⌥⌘2) to drag files between them.

**Metadata & columns** — Toggle columns: Name, Date Modified/Created/Added, Size (with on-demand **folder size**), Kind, Extension, and — lazily from Spotlight — **Duration**, **Dimensions**, and **Tags**. Widths and choices persist.

**Preview & Get Info** — Toggleable preview pane (⇧⌘P / the **Details** button) and a rich **Get Info** window with editable name, tags, comments, permissions, and Open With. Set/edit colored **Finder tags** and comments.

**Search** — Instant name filter, plus recursive **Spotlight search** with scope (This Folder / This Mac) and kind filters.

**Sidebar** — **Recents** (recent files, like Finder), **Recent Folders** (folders you've actually worked in), customizable **Favorites**, **Cloud** (iCloud / Google Drive / OneDrive / Dropbox), **Locations** (disks, with eject), and **Network** (Bonjour SMB servers).

**Dock menu** — Right-click Navigator in the Dock for New Window, New Tab, Find…, Go to Folder…, Connect to Server…, Applications, Volumes, Home.

**System integration** — Finder **Open With** + **"Open in Navigator"** Services entry, **Open in Terminal**, **Quick Look** (Space / ⌘Y), **Share…**, and folders open faster on network drives than Finder.

**Google Drive** — Right-click an item inside Google Drive for **Copy Google Drive Link** and **Open in Google Drive** — a real `drive.google.com` link (read from Drive's own item ID) that resolves for anyone with access, so you can share a location without pasting a local path full of your username. And a Google Drive path **pasted from another user** (their home + account email) is auto-remapped to your own Drive account in the address bar, so shared-drive paths just resolve.

## Keyboard shortcuts
| Shortcut | Action |
|---|---|
| ⌘L / ⌘F | Focus address bar / search |
| ⌘T / ⌘W / ⌘N | New tab / close tab / new window |
| ⇧⌘N / ⌥⌘N | New folder / new text file |
| ⌘C / ⌘X / ⌘V | Copy / cut / paste files |
| ⌘I / ⌘D / ⌘Y or Space | Get Info / Duplicate / Quick Look |
| ⌘⌫ / ⇧⌘⌫ | Move to Trash / Empty Trash |
| ⌘[ / ⌘] / ⌘↑ | Back / Forward / Enclosing folder |
| ⇧⌘P / ⌥⌘S / ⌥⌘2 | Toggle preview / sidebar / dual pane |
| ⇧⌘. / ⌘R / ⌘Z / ⌘K | Show hidden / Refresh / Undo / Connect to Server |
| ⌘, / F2 | Settings / Rename selected |
| ⌘ + scroll | Resize / cycle the view (Details ↔ Columns ↔ Icons) |
| ⌘+ / ⌘− / ⌘0 | Zoom in / out / fit *(image viewer)* |

## Build from source
Needs the **Xcode Command Line Tools** (`xcode-select --install`). One command builds, signs, and installs to `/Applications`:

```bash
git clone https://github.com/michaelericksonh5/Navigator.git NavigatorApp
cd NavigatorApp
bash rebuild.sh
open /Applications/Navigator.app
```

- `rebuild.sh` compiles `main.swift`, generates the icon from `AppIcon.png`, assembles the universal `.app` bundle (arm64 + x86_64), and code-signs it.
- `quickbuild.sh` is a faster arm64-only variant for iterating.

### Stable code signing (recommended, optional)
If a self-signed **"Navigator Dev"** certificate exists in your login keychain, `rebuild.sh` signs with it so the app's identity stays constant across rebuilds — which means macOS **remembers** its Full Disk Access / folder-access grants instead of re-prompting every build. Without it, the build falls back to ad-hoc signing (still runs; permissions just reset per build). A backup of the cert lives in `~/.navigator-signing/`.

### Sharing with someone else
Send them the [Releases](../../releases/latest) download (universal, macOS 14+). Because it isn't notarized, their first launch needs the one-time **right-click → Open** and the permission steps above. Truly zero-warning distribution would require Apple Developer ID signing + notarization ($99/yr Apple Developer Program).

## Known limitations
- **Auto-refresh** covers local and cloud (File Provider) folders. **SMB network shares** don't push change notifications, so use **⌘R** (or revisit) to refresh those. Files added on a cloud service's *other* devices appear only once that service syncs them down to this Mac.
- **Cannot fully replace Finder** as the system folder handler — macOS locks that to Finder. Navigator registers as a folder app instead (Open With, the Services entry, and `open -b com.merickson.navigator <folder>` all work).
- **Empty Trash** clears only the home volume's `~/.Trash`, not per-volume trashes.
- Some protected-folder operations require **Full Disk Access** (see permissions above).
- Not notarized — hence the one-time first-launch step.

## License
Personal project. No warranty.

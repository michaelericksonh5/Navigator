# Navigator — Permissions Guide

Everything macOS will ask Navigator for, what each one actually buys you, and how
to check whether it stuck. Written against **macOS 26 (Tahoe)**; the System
Settings paths differ on earlier versions.

Navigator's built-in **Setup Assistant** (Help ▸ Setup Assistant) walks through
most of this and shows live status. This document is the reference behind it —
useful when handing Navigator to someone new, or when something isn't working and
you want to know which switch is responsible.

---

## The short version

Grant **Full Disk Access** and you're done with file access. Everything else is
either optional or granted on demand the first time you use the feature.

| Permission | Needed for | Required? |
|---|---|---|
| Full Disk Access | All file browsing, in one grant | **Strongly recommended** |
| Files & Folders | Desktop / Documents / Downloads / network / USB — *individually* | Only if you skip Full Disk Access |
| Automation ▸ Finder | Saving comments in Get Info | Optional |
| Automation ▸ Photoshop | Remove BG, Chroma Key, Quick Export as PNG | Only for those features |
| Automation ▸ After Effects | Chroma Key | Only for that feature |
| Accessibility | The **one-keystroke** Open/Save dialog jump (⌃⌥⇧⌘G) | Optional |
| Finder extension | Navigator's submenu in Finder's right-click menu | Optional |
| Local Network | Discovering file servers for the sidebar | Optional |
| Screen Recording | **Nothing.** Navigator never asks. | Never |

---

## 1. Full Disk Access — do this one first

**What it's for:** letting Navigator read and write anywhere you can. It's a file
explorer; this is the permission that makes it one.

**Why it's the shortcut:** Full Disk Access *supersedes* the individual
Desktop / Documents / Downloads / network / removable-volume permissions. Grant
it and macOS stops asking about the others — it will even **hide** those
individual switches, because they no longer apply.

That's worth knowing, because it surprises people: if you go looking for a
"Desktop" switch under Navigator in Files & Folders and it isn't there, that's
usually not a bug. It means Full Disk Access already covers it.

**How:**
1.  ▸ System Settings ▸ Privacy & Security ▸ **Full Disk Access**
2. Find **Navigator** and switch it on (use **+** and pick `/Applications/Navigator.app` if it isn't listed)
3. Quit and reopen Navigator

Or from inside the app: **Navigator ▸ Grant Full Disk Access…**

---

## 2. Files & Folders — only if you skip Full Disk Access

**What it's for:** access to specific protected locations, one at a time —
Desktop, Documents, Downloads, network volumes, removable (USB/external) drives.

**Two things about this pane that confuse everyone:**

- **A location only appears after Navigator has asked for it.** macOS doesn't
  pre-list them. If "USB & external drives" isn't under Navigator, it's because
  nothing has been plugged in and browsed yet — not because it's broken. In the
  Setup Assistant these show as *Not yet asked*, with an **Ask macOS** button
  that triggers the real system prompt.
- **If you have Full Disk Access, these are hidden and irrelevant.** See above.

**How:**  ▸ System Settings ▸ Privacy & Security ▸ **Files and Folders** ▸ expand
**Navigator**, then toggle what you want.

If you accidentally deny one, this pane is where you undo it — a denial sticks
until you change it here, and macOS won't ask twice.

---

## 3. Automation — per-app, granted on demand

Navigator asks other apps to do work for it. Each target app is a separate grant,
and each is requested the first time you use the corresponding feature.

| Target | Used by |
|---|---|
| **Finder** | Saving a comment in Get Info (Finder owns comment metadata) |
| **Adobe Photoshop** | Remove Background, Chroma Key, Quick Export as PNG, AI upscale re-cuts |
| **Adobe After Effects** | Chroma Key |

**How:**  ▸ System Settings ▸ Privacy & Security ▸ **Automation** ▸ expand
**Navigator** and enable the apps listed underneath.

If you decline one of these prompts, the feature fails quietly-ish until you come
back here — Navigator will tell you it was a permission problem, but it can't
re-prompt you itself. macOS only asks once.

---

## 4. Accessibility — optional, and only for one thing

**What it's for:** exactly one feature — the **one-keystroke** version of the
Open/Save dialog bridge (**⌃⌥⇧⌘G**), which types ⇧⌘G, pastes the path, and
presses Return into whatever app is in front of you. Sending keystrokes to
another application is what requires this.

**You do not need it for the normal path.** **⌃⌥⌘G** (copy the path) works with
Accessibility switched off — it's registered a different way specifically so it
wouldn't need this. Copy, then press ⇧⌘G and ⌘V in the dialog yourself. Three
keystrokes, no permission.

**The catch, stated plainly:** macOS identifies an app for Accessibility by its
code signature. Navigator is signed with a local development certificate and has
no Team ID, so **rebuilding or updating Navigator can drop this grant** and you'll
have to re-enable it. That's the tradeoff for a self-distributed app; nothing in
Navigator can work around it.

**How:**  ▸ System Settings ▸ Privacy & Security ▸ **Accessibility** ▸ enable
**Navigator**. Quit and reopen the app afterwards.

---

## 5. The Finder extension — optional

**What it's for:** Navigator's own submenu inside Finder's right-click menu, so
you can act on files from Finder without switching apps.

**Where to find it, because the name is misleading:**  ▸ System Settings ▸
General ▸ **Login Items & Extensions** ▸ **File Providers** ▸ enable **Navigator**.

Yes — *File Providers*. On macOS 26 that's the sheet Finder Sync extensions live
in, alongside things like Google Drive's helper. There is no section called
"Finder Extensions" any more, and the category literally named "Finder" is Quick
Actions, which is something else entirely.

**If Navigator isn't in that list:** launch Navigator once and look again. macOS
registers the extension when the app runs, and a fresh install or an update
re-registers it. That's also why the release notes say to open Navigator once
after updating.

---

## 6. Local Network — optional

**What it's for:** finding SMB file servers on your network so they show up in
Navigator's sidebar automatically. Without it you can still connect manually with
**Go ▸ Connect to Server (⌘K)**.

**How:**  ▸ System Settings ▸ Privacy & Security ▸ **Local Network** ▸ enable
**Navigator**.

---

## 7. Things Navigator never asks for

- **Screen Recording.** Some file-dialog utilities need it (Default Folder X
  screenshots dialogs to detect Dark Mode). Navigator does not. If something asks
  you for this on Navigator's behalf, be suspicious.
- **Your password / admin rights.** Navigator never needs elevated privileges.
  Changing a file's permissions in Get Info uses your own access, and fails with a
  clear message if you don't own the file.

---

## Verifying what's actually granted

The Setup Assistant (**Help ▸ Setup Assistant**) is the easy answer — it probes
what Navigator can genuinely *do* rather than reading a list, which is more
truthful than the System Settings panes in a few cases.

If you'd rather check from a terminal:

```bash
# Everything macOS has recorded for Navigator (2 = allowed, 0 = denied)
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, indirect_object_identifier, auth_value
     from access where client='com.merickson.navigator' order by service;"
```

Full Disk Access lives in the **system** database, not your user one, so it won't
appear above:

```bash
sudo sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, auth_value from access
     where client='com.merickson.navigator' and service like '%AllFiles%';"
```

Finder extension registered and enabled? A leading `+` means enabled:

```bash
pluginkit -mAvvv -p com.apple.FinderSync | grep -A1 navigator
```

---

## Troubleshooting

**"A switch the guide mentions isn't there."**
Most often Full Disk Access is on and macOS has hidden the redundant per-folder
switches. Otherwise, the permission hasn't been requested yet — use the Setup
Assistant's **Ask macOS** button for that row.

**"I denied a prompt by accident."**
macOS won't ask again. Go to the matching pane above and switch it on manually.

**"A feature stopped working after I updated Navigator."**
Check **Accessibility** first — that's the one keyed to the code signature and
the one most likely to have been dropped. Everything else survives updates.

**"Navigator vanished from Login Items & Extensions."**
Launch it once; it re-registers the extension on run.

**"Reveal in Finder still opens Finder, not Navigator."**
That one isn't a permission and can't be changed. The macOS API other apps call
for this (`activateFileViewerSelecting`) names Finder specifically and takes no
alternative — so every app's "Reveal in Finder" will always be Finder. Setting
Navigator as the default handler for *folders* is a separate thing and does work
for double-clicking a folder.

---

## For whoever sets up a new machine

1. Copy `Navigator.app` to `/Applications`
2. Right-click it ▸ **Open** ▸ confirm (it's self-signed, so first launch warns)
3. Let the **Setup Assistant** run — it appears automatically on first launch
4. Grant **Full Disk Access** when it asks. That's the one that matters.
5. Enable the **Finder extension** if you want the Finder right-click menu
6. Everything else can wait until a feature asks for it

Skipping all of it still leaves a working file browser — it just won't reach
protected folders.

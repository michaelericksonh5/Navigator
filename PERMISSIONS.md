# Navigator — Permissions Guide

Everything macOS will ask Navigator for, what each one actually buys you, and how
to check whether it stuck. Written against **macOS 26 (Tahoe)**; the System
Settings paths differ on earlier versions.

Navigator's built-in checklist (**Navigator ▸ Setup & Permissions…**, or
Help ▸ Setup Assistant — same window) walks through most of this, shows live
status, and has a button per row that opens the exact System Settings pane. It also
covers two things that aren't macOS permissions at all but fail the same way: the AI
provider credentials (§4b) and whether Navigator is your default image viewer.
**Prefer the buttons to this document.** Two of these panes are genuinely hard to
find by name, and one of them (Accessibility, §4) shares its name with an
unrelated pane — a click cannot land in the wrong place, a written path can.

This document is the reference behind that window — useful when handing Navigator
to someone new, or when something isn't working and you want to know which switch
is responsible.

---

## The short version

Grant **Full Disk Access** and you're done with file access. Everything else is
either optional or granted on demand the first time you use the feature.

| Permission | Needed for | Required? |
|---|---|---|
| Full Disk Access | All file browsing, in one grant | **Strongly recommended** |
| Files & Folders | Desktop / Documents / Downloads / network / USB — *individually* | Only if you skip Full Disk Access |
| Automation ▸ Finder | Saving comments in Get Info | Optional |
| App Management *(§8)* | **Navigator updating itself** | Recommended |
| Automation ▸ Photoshop | Remove BG, Chroma Key, Quick Export as PNG | Only for those features |
| Automation ▸ After Effects | Chroma Key | Only for that feature |
| Accessibility *(Privacy & Security — not the sidebar one, see §4)* | The **one-keystroke** Open/Save dialog jump (⌃⌥⇧⌘G) | Optional |
| AI provider keys *(not a macOS permission — see §4b)* | Restyle, AI upscaling, Prep for AI | Only for those features |
| Finder extension | Navigator's submenu in Finder's right-click menu | Optional |
| Local Network *(§6)* | Discovering SMB file servers for the sidebar | Optional |
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

### There are two panes called "Accessibility". Read this before you go looking.

This is the one thing in this document that has actually cost someone an evening,
so it gets its own heading.

* **System Settings ▸ Accessibility** — the item in the **left sidebar**, with the
  blue figure icon. This is VoiceOver, Zoom, Hover Text, Captions. It is about
  *using* your Mac. **It contains no list of apps and no Navigator switch.** If
  you are looking at Display / Spoken Content / Motor, you are in the wrong pane.
* **System Settings ▸ Privacy & Security ▸ Accessibility** — a completely
  separate pane that happens to have the identical name. It is headed **"Allow the
  applications below to control your computer"** and is a list of apps with
  on/off switches. **This is the one you want.** Navigator is in that list.

That header sentence is the reliable way to tell them apart. Same name, same
spelling, different pane.

**How, without the hunt:** open Navigator ▸ **Setup & Permissions…**, scroll to
**Accessibility (one-key dialog jump)** and press its **Open Settings** button. It
opens the right pane directly. (The Settings window's dialog-bridge section and
Navigator's own "needs Accessibility" alert have the same button.)

**How, by hand:**  ▸ System Settings ▸ **Privacy & Security** ▸ scroll down to
**Accessibility** ▸ find **Navigator** in the list ▸ switch it on. If Navigator
isn't listed, click **+**, press ⇧⌘G, type `/Applications/Navigator.app`. Quit and
reopen the app afterwards.

---

## 4b. AI provider keys — not macOS permissions, but the same kind of blocker

Navigator's AI features run through three providers. These aren't System Settings toggles,
but they fail in the same "why isn't this working" way, so they belong on the checklist.

| Provider | What it powers | How it's set up | Stored where |
|---|---|---|---|
| **Vertex** (Google, company-metered) | Restyle, Imagen upscale, Prep-for-AI models | Browser sign-in, **no key** — AI ▸ Sign in to Vertex (Imagen)… | `~/.h5g-ai-gen/token.json`, ~30 days |
| **fal.ai** | AI upscaling (SeedVR2, Crystal, AuraSR, Topaz, Recraft) | AI ▸ API Keys… | your **login keychain** |
| **OpenAI** | not wired up yet — reserved for gpt-image surfaces | AI ▸ API Keys… | your **login keychain** |

**Vertex is a sign-in, not a key.** If something tells you to install `gcloud`, run
`gcloud auth`, or set `GOOGLE_APPLICATION_CREDENTIALS`, that is the wrong path and it also
breaks the fal/OpenAI paths. Sign-in lasts about 30 days, then asks once more.

### The keychain prompt after every Navigator update

This one is guaranteed to bite, so it gets stated plainly.

Navigator is self-signed. **Updating it re-signs the app, which invalidates the keychain's
saved permission for anything Navigator stored earlier.** So the first AI action after an
update pops:

> Navigator wants to access key "com.merickson.navigator.apikeys" in your keychain.

That is normal and it is not a sign anything is wrong. Enter your **login keychain**
password (the same one you log into the Mac with) and choose **Always Allow** so it stops
asking for this build.

**Your key is still there.** If you dismiss that prompt, Navigator now says so explicitly —
"macOS blocked access to your saved fal.ai key" — rather than telling you to add a key you
already added. If you ever see the older "Add your fal.ai API key first" wording, that one
really does mean no key is stored.

This is the same tradeoff as Accessibility in §4: both are keyed to the code signature, and
nothing in Navigator can avoid it without a paid Developer ID.

### Checking what's set

```bash
# Vertex: signed in as who?
node ~/.claude/skills/h5g-ai-connect/client.mjs whoami

# fal / OpenAI: configured, and from which source?
node ~/.claude/skills/h5g-ai-connect/keys.mjs status
```

Never paste a key into a chat window or a support ticket. `keys.mjs set fal` prompts for it
with the input masked.

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

## 8. App Management — how Navigator updates itself

**What it's for:** installing an update. Navigator downloads the new build and replaces
`/Applications/Navigator.app`, and macOS classes replacing an app bundle as App Management.

**Why it's worth checking even though nothing prompts you:** if it's off, the download
succeeds and the swap silently doesn't. You stay on the old version, no error appears, and
the only symptom is that the same update keeps offering itself. That's a confusing failure
to diagnose from the outside, which is the whole reason this section exists.

**How:**  ▸ System Settings ▸ Privacy & Security ▸ **App Management** ▸ enable **Navigator**.

macOS gives apps no way to read this setting back, so the Setup Assistant lists it without a
status — it can point you at the pane, but only you can see the switch.

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

The checklist (**Navigator ▸ Setup & Permissions…**, or Help ▸ Setup
Assistant — the same window) is the easy answer — it probes
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

# Setting up Navigator on a new Mac

A template. Fill in the placeholders for your own team and share the filled-in copy
**internally** — a file listing your server addresses does not belong in a public repo.

Everything here is a one-time setup. Budget ten minutes.

---

## 1. Install

1. Download `Navigator.zip` from the [latest release](../../releases/latest).
2. Unzip it and drag **Navigator.app** to `/Applications`.
3. Right-click it → **Open** the first time. macOS blocks unsigned apps on a double-click;
   right-click → Open gives you the "open anyway" button. You only do this once.

## 2. Connect the VPN — before anything else

> **Fill in:** which VPN client your company uses, and where to get it.

The file shares are only reachable through the VPN. Connect it first, with your normal
work login.

If you skip this, Navigator will tell you: a drive that won't connect reports
**"Can't reach *server*"** and says the address and password are probably fine. If it
instead says the server **refused your credentials**, the VPN is working and it's the
login that's wrong. The two messages are deliberately different so you're not guessing.

## 3. Grant the permissions

Open **Navigator ▸ Setup & Permissions…**

macOS keeps apps out of your files until you say otherwise, so this window lists what
Navigator can currently reach and gives you an **Ask macOS** button per item. Work down
the list. A row with no button needs nothing from you.

`PERMISSIONS.md` in this repo explains each one and why it's needed, if you want the
detail before clicking.

## 4. Add the network drives

Still in **Setup & Permissions…**, find the **Network drives** section, paste your team's
share addresses — one per line — and click **Add Drives**.

> **Fill in:** your team's addresses.
> ```
> G Drive = smb://YOUR-SERVER/YourShare
> X Drive = smb://YOUR-OTHER-SERVER/YourOtherShare
> ```

`Label = address` names the drive in your sidebar; a bare address is fine too and gets
named after the share. Lines starting with `#` are ignored, so you can annotate the list.

Nothing connects yet — the addresses are just saved as sidebar drives.

**Alternatively**, if a colleague sends you a Navigator favourites file, use
**Add Drives ▸ Import from File…** (or File ▸ Import Favorites…) to get their exact
sidebar layout.

## 5. First connect

Click a drive in the sidebar. macOS asks for your credentials — use your **normal work
login**, not a personal account. Tick "remember in my keychain" and you won't be asked
again.

That's it. After this, drives reconnect on their own after a reboot or a VPN drop; there's
no trip to Finder and no "Reconnect" dance.

---

## What to expect once you're in

- **Folders open immediately**, even huge ones. File names appear straight away; sizes and
  dates fill in behind them, blank until the real value arrives rather than showing a
  wrong one.
- **Big folders are fast the first time you open them**, because a colleague who opened
  them earlier left a shared index on the share (a hidden `.navigator` folder at the top
  of each share). It's just cached file sizes and dates — no credentials, nothing private.
  Delete it any time and it rebuilds.
- **Someone else's changes show up.** New and deleted files are always detected from a live
  listing, so nothing is ever missed, whether or not they use Navigator.

If a share ever feels slow, `PERFORMANCE.md` explains what is and isn't fixable from the
client, with measurements.

## If something goes wrong

| Symptom | Cause |
|---|---|
| "Can't reach *server*" | VPN not connected, or the server name is wrong |
| "*server* refused those credentials" | VPN is fine — wrong username or password |
| "*server* has no share by that name" | The part of the address after the server name is wrong |
| Drive in the sidebar does nothing | Added before this version; remove it and re-add via Setup |
| A folder shows no sizes or dates | They're still loading, or those columns are switched off for that folder |

macOS blocks the app on first launch — see step 1, right-click → Open.

# Navigator — Network Performance: findings & architecture

How Navigator makes SMB / Google Drive / local browsing fast, what we measured,
what we do that Finder doesn't, and what's genuinely out of our hands.

## What we measured (High 5 `corp-pure02`, over GlobalProtect VPN)

Numbers taken from the live `artSource` share (665 top-level folders):

| Measurement | Result | Meaning |
|---|---|---|
| `readdir` of `/Volumes/Games/artSource` (DFS) | **~58 s** | The directory *listing itself* is the cost |
| `readdir` of `/Volumes/cifs-games/Games/ArtSource` (direct) | **~58 s** | Same — DFS is **not** the difference |
| Second (warm) read | **~58 s** | macOS's 60 s dir-cache expires before a 58 s read finishes |
| Per-item metadata stat | ~91 ms serial; instant once cached | Metadata is **not** the bottleneck |
| VPN round-trip to server (`ping`) | **~80 ms** | — |
| Enumeration cost per entry | **~87 ms** (665 ÷ 58 s) | ≈ **one network round-trip per directory entry** |

**Root cause:** `~80 ms RTT × ~one round-trip per entry × 665 entries ≈ 58 s`. The
server (or the VPN path) is not returning directory entries in efficient batches,
so latency is paid per-entry. This is a **server/network characteristic** — a
plain shell `ls` is exactly as slow as Navigator or Finder. On the office LAN
(~1 ms RTT) the same folder would list in **~1 second**.

Also measured: **Spotlight (`NSMetadataQuery`) does not index SMB shares or
Google Drive (File Provider)** — so the old "search this folder" returned nothing
on exactly the drives people search most.

## What Navigator does about it (client-side levers we fully control)

1. **Bulk enumeration.** Network folders are read with
   `enumerator(includingPropertiesForKeys:)` → `getattrlistbulk` under the hood,
   which returns **names + metadata in one batched pass**. Research (Tempelmann,
   Tsai) shows `readdir` + a `stat` per file is the *slowest* method on SMB; we no
   longer do that.
2. **Persistent directory cache.** Listings are cached to disk
   (`~/Library/Caches/Navigator/dircache.json`) and survive relaunches/reboots.
   The 58 s enumeration is paid **once**, not every session.
3. **Conditional revalidation (mtime).** On revisit we stat *just the folder*
   (one round-trip) and compare its modification date to the cached one. Unchanged
   → serve the cache, **no re-listing**. Changed (files added/removed bump the dir
   mtime) → refresh **immediately**. A 15-minute backstop + ⌘R cover the rest.
4. **No background crawling.** We deliberately do *not* pre-enumerate drives in the
   background: on a degraded VPN that competes with the user's own navigation for
   the one choked connection and makes browsing hang. The persistent cache + mtime
   revalidation already make revisits instant with **zero** background traffic. (A
   background indexer was tried and removed for this reason — see git history.)
5. **Never blocks the UI.** All enumeration, metadata, mounting, copying, image
   decoding, and even the conflict/permissions stats run **off the main thread**.
   A stalled mount shows a quiet "responding slowly…" note instead of a beachball.
6. **Byte-level copy progress** via `copyfile` (clones on APFS, byte-copies with a
   moving progress bar over the network).
7. **Recursive search that works on SMB & Google Drive** — a streaming filesystem
   walk (name *or* extension, e.g. `png`), because Spotlight can't index those.
8. **SMB client tuning** written to a per-user `nsmb.conf` (no sudo):
   `dir_cache_async_cnt=100` (pipeline many directory queries to hide RTT),
   `dir_cache_max=180s` + `max_cached_per_dir=10000` (cache big folders longer),
   `notify_off`. Takes effect on the next mount. *Effect over a specific VPN
   varies — measure via the perf log.*
9. **Direct-share paths over DFS**, mounted via NetFS (no Finder popup).

## Better than Finder / macOS, concretely

- **Persistent cross-launch cache** — Finder re-lists SMB folders every session; we
  don't. First-open-of-the-day is instant for us.
- **mtime revalidation** — Finder's dir cache is time-based (expires, re-lists even
  when nothing changed); ours re-lists **only when the folder actually changed**,
  and refreshes instantly when it did. Fresher *and* faster.
- **No beachball** — Finder blocks on stalled SMB mounts; Navigator's window stays
  live with a status note.
- **Working search on SMB/cloud** — Finder search leans on Spotlight, which is blind
  to these drives; our recursive walk isn't.

## What we cannot fix (it's the server/network, not the client)

- The **first** listing of a folder must happen once — no client can list a folder
  faster than the server returns it.
- **~80 ms VPN latency × one-round-trip-per-entry** is the real wall. Fixes live on
  the **server/network** side: SMB directory-response batching, VPN MTU/fragmentation,
  signing/encryption transaction sizes — or simply being on the LAN.

### Diagnostics
Perf timings are logged. View in **Console.app** (or `log stream`) filtered by
subsystem **`com.merickson.navigator`**: `readdir`/`network bulk enumerate`/`warm`
lines report item counts and milliseconds, so any slow folder is measurable.

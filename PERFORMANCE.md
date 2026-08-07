# Navigator — Network Performance: findings & architecture

How Navigator makes SMB / Google Drive / local browsing fast, what we measured,
what we do that Finder doesn't, and what's genuinely out of our hands.

> **Revised 2026-08-07.** The previous version of this document had the root cause
> backwards: it reported the directory *listing* as the ~58 s cost and stated that
> "metadata is not the bottleneck." Re-measured, it is the exact opposite. Two of the
> levers below were built on that inverted premise, and one implementation bug
> (see "The truncation guard", below) silently prevented the cache from ever holding
> the large folders it existed for. Numbers here are from 2026-08-07 on GlobalProtect.

## What we measured (High 5 shares, over GlobalProtect VPN)

Ping RTT: **77–114 ms** to both `corp-pure02` and `CORP-DC01`.

`/Volumes/Games-1/artSource`, 669 top-level entries:

| Measurement | Result | Meaning |
|---|---|---|
| `readdir` (names + `d_type` only) | **0.43 s** | The listing is **batched** and effectively free |
| `resourceValues` per entry (what the enumerator does) | 59.5 s — 89 ms/entry | |
| Raw `lstat` per entry | 61.5 s — 92 ms/entry | Not an API artifact |
| 8 / 16 / 32-way concurrent `lstat`, cold | 58.7 / 58.8 / 59.7 s | **Concurrency buys nothing** — smbfs serializes |
| `getattrlistbulk`, all 669 in **one** syscall | 71.1 s — 106 ms/entry | The bulk API is no better; slightly worse |
| Any of the above, warm | ~0 ms | smbfs caches an entry once fetched |

`/Volumes/data/Public`, 116–118 entries: `readdir` **0.24 s**; full metadata enumerate
**10.8–13.1 s**.

**Root cause:** ~89 ms per entry ≈ **one network round trip per entry**, and it is paid
for *metadata*, not for the listing. `readdir` returns hundreds of names in a couple of
round trips; asking for size or date costs one round trip per file. The old
"~80 ms RTT × one round-trip per entry" formula was right — it just applies to the
attribute fetch, not the enumeration.

### Why Windows looks faster, and why we can't simply copy it

SMB2's `QUERY_DIRECTORY` response **already carries** size, timestamps and attributes for
every entry. That is how Explorer shows sizes instantly, and macOS is clearly receiving it
(that is where `readdir`'s `d_type` comes from). macOS's `smbfs` then discards the rest and
re-queries per file when asked for an attribute. All four APIs above were tested looking
for a way around it; there isn't one from userspace. The per-user `nsmb.conf` we write
(`dir_cache_async_cnt=100`, `max_cached_per_dir=10000`, `dir_cache_max=180s`) does not
change it either.

So the data is on the wire and the OS won't hand it over. **The only client-side lever is
to not ask** — and to remember the answers we do get.

Also measured: **Spotlight (`NSMetadataQuery`) does not index SMB shares** — so the old
"search this folder" returned nothing on exactly the drives people search most.

## What Navigator does about it

1. **Indexable columns by default on shares, unindexable ones off.** A network folder nobody
   has arranged shows Name, Ext, Kind, Size and Date Modified, sorted by **name** — the sort
   matters, because a size/date sort would need every row's attributes before anything could
   paint. Name/Ext/Kind cost nothing (`readdir` plus derivation); Size and Date Modified cost a
   round trip each but are answered in bulk by the shared index below, and render blank until
   their real values arrive, so nothing on screen is ever wrong and navigation is never held up.

   Owner, Created, Accessed, Duration and Dimensions stay off by default: no index covers them,
   Owner is a stat per *cell render*, and Duration/Dimensions read file headers. Not forbidden —
   turn one on for a folder and you get it, and the slower load, and it is remembered.
   `NetworkColumnRules` owns this and is unit-tested.

   (Size and Modified were briefly off by default too, when they cost 59 s for artSource. The
   index changed that premise; they came back on once a folder answered in ~1 s.)
2. **Skip the metadata pass entirely when nothing needs it.** If no visible column and no
   sort key requires per-file data, the names-only listing *is* the finished answer and
   the expensive pass never runs.
3. **Visible rows first, and repaints are coalesced.** When attributes *are* wanted, rows arrive from `readdir` without
   them and whatever is actually on screen is fetched first, a screenful of runway either
   side, re-prioritised on every scroll. You look at ~30 rows, not 669: **~1 s** to fill a
   screen instead of 59 s to fill the folder. The full pass still runs behind it and still
   writes the cache, so the folder ends up complete on disk. Double work is nearly free
   because smbfs caches an entry once fetched. Hydration, the sweep and background repair all
   funnel through one coalescer capped at ~5 repaints/second — each of them reassigns `items`,
   and every reassignment is a full reload of a table that may hold 669 rows, which unchecked
   is dozens of reloads in a few seconds and reads as jitter. Queued work is cancelled when the
   folder changes so a batch fetched for the old folder can never land on the new one's rows.
4. **Shared folder index on the share itself.** The answer is the same for everyone on the
   team, so one person's expensive listing is written back for the rest:
   `<volume-root>/.navigator/<hash>.json`, 669 entries in 39 KB. Measured on artSource:
   **68 s → ~1 s.** Written only after a complete sweep and throttled (a write costs ~5 s),
   skipped for folders under 40 entries, and hashed on the path *relative to the volume root*
   so an index written by someone whose share is mounted at `/Volumes/Games` still resolves
   for a colleague at `/Volumes/Games-1`.

   **The index never decides what exists.** Presence always comes from the live `readdir`,
   which is free; the index only supplies attributes for names that listing already confirmed.
   A file a non-Navigator user added is simply unindexed and gets fetched individually; a file
   they deleted has an entry nobody looks up. A stale index cannot invent or hide anything.
   When the index covers ≥80% of the folder, the sweep is skipped entirely and only the
   unknown names are fetched — in practice 2 of 671, because `readdir` sees the DOS-hidden
   files the enumerator filters out.

   **Repair is incremental, not a re-sweep.** When the folder's mtime no longer matches what the
   index recorded, the index is patched in the background: `readdir` has already established
   which files exist at no cost, so only names the index has never seen cost a round trip, and
   names it has that the listing lacks are dropped (that is how deletions leave). Three new files
   costs three stats, not 669 — the first version re-swept the whole folder and measured **three
   minutes** while competing with foreground work. Rebuilds are also deduplicated per folder:
   every open tab runs its own `loadNetwork`, so three tabs previously started three concurrent
   sweeps of the same folder over a connection that serializes anyway.

   `savedAt` records the last FULL sweep and incremental repairs carry it forward unchanged. That
   is deliberate: it guarantees a full re-read eventually happens, which is the only thing that
   catches a file edited **in place** (same name, same directory mtime, different size). Until
   then, visible-rows-first re-fetches whatever is on screen, so anything actually looked at is
   correct regardless.

   Written temp-then-`rename(2)`, deliberately **not** `FileManager.replaceItemAt`: that
   preserves extended attributes, and an SMB volume stores those in AppleDouble `._` sidecars,
   so the tidy single index file arrived with a 4 KB twin beside it.
5. **Persistent directory cache.** Listings are cached to
   `~/Library/Caches/Navigator/dircache.json` and survive relaunches and reboots, so an
   expensive folder is paid for once rather than every session.
6. **Conditional revalidation (mtime).** On revisit we stat *just the folder* (one round
   trip) and compare its modification date to the cached one. Unchanged → serve the cache,
   no re-listing. Changed → refresh immediately. 15-minute backstop, plus ⌘R.
7. **No background crawling.** We deliberately do *not* pre-enumerate drives. This has now been
   decided twice, so the reasoning is recorded here rather than rediscovered a third time.

   It was built once (`2eefe4c`, v1.4.41) and removed (`d49b84a`) because its 58 s enumerations
   competed with the user's own navigation for the one choked connection and made browsing hang.
   Nothing since has changed that: attribute fetches are serialized by the SMB client and cannot
   be parallelized, so every entry a crawler reads is one the foreground waits behind — and the
   serial `sweepQueue` now makes that queueing explicit.

   The scale rules it out on its own. `readdir` is cheap (666 names in 0.7 s) but attributes cost
   89 ms/entry at best and ~500 ms/entry on a degraded VPN, so a 50k-file tree is ~7 hours of
   serialized traffic and a 200k-file tree ~28 hours. Merely *sampling* six of artSource's 671
   top-level folders exceeded a 10-minute timeout.

   And a crawl is not a one-time payment, which is the subtler reason. Staleness is detected by
   comparing directory mtime **when you navigate somewhere** — nothing watches a folder you don't
   open. So a crawled index for an unvisited folder decays silently until `maxAge` and then has to
   be crawled again: a recurring multi-hour treadmill across a tree whose folders are, by
   definition, mostly ones nobody opens.

   Build-as-you-go has the right economics instead: the folders you actually use get indexed on
   first visit, stay fast, and repair in ~5 s when someone changes them; folders you never touch
   cost nothing. Zero background traffic.
8. **Never blocks the UI.** Enumeration, metadata, mounting, copying, image decoding and
   the conflict/permission stats all run off the main thread. A stalled mount shows a quiet
   "responding slowly…" note instead of a beachball.
9. **Direct mounting via NetFS**, never `NSWorkspace.open(smb://…)` — no Finder hand-off,
   no "Connecting to…" window. Measured 1.6–2.5 s to mount a share with stored credentials.
10. **Recursive search that works on SMB** — a streaming filesystem walk, because Spotlight
   is blind to these volumes.

### The truncation guard (fixed 2026-08-07)

Worth recording, because it made levers 5 and 6 look like they didn't work. The metadata
pass used to be discarded whenever it returned fewer rows than the names-only pass, on the
theory that a short result meant it had been aborted. But the two passes filter hidden
files differently: names-only matches a leading dot, while `.skipsHiddenFiles` honours the
**DOS hidden attribute**. On a Windows-authored share the metadata pass legitimately returns
fewer rows (measured 116 vs 118 on `//corp-pure02/data` — `Thumbs.db` and friends), so a
correct result was thrown away as if truncated, and the `DiskCache.put` below it was never
reached. Two consequences: Size and Date Modified stayed blank *permanently* rather than
just during loading, and the largest folders were never cached — `Public` and `artSource`
were absent from `dircache.json` while 24 small folders sat in it happily. Completion is now
tracked explicitly instead of inferred from row counts.

One consequence of the fast path: DOS-hidden files (`Thumbs.db`, `desktop.ini`) are visible
on a share, because filtering them requires exactly the per-file stat we are avoiding.

## Better than Finder / macOS, concretely

- **Persistent cross-launch cache** — Finder re-lists SMB folders every session; we don't.
- **mtime revalidation** — Finder's dir cache is time-based and re-lists even when nothing
  changed; ours re-lists only when the folder actually changed. Fresher *and* faster.
- **Cheap-by-default columns** — Finder asks for every column it shows, on every row.
- **Visible-rows-first metadata** — Finder fills a folder in enumeration order.
- **A team-shared index** — the first colleague to open a big folder makes it fast for everyone.
- **No beachball** — Finder blocks on stalled SMB mounts; our window stays live.
- **Working search on SMB** — Finder search leans on Spotlight, which can't see these drives.

## What we cannot fix (it's the server/network, not the client)

- The **first** listing of a folder must happen once — no client lists a folder faster than
  the server returns it.
- **~89 ms per attribute fetch** is the wall, and macOS gives us no batched path to it.
  Real fixes live server-side or on the network: SMB directory-response batching, VPN
  MTU/fragmentation, signing/encryption transaction sizes — or being on the LAN, where the
  same folder would fill in about a second.

### Diagnostics

`~/Library/Logs/Navigator.log` carries the decisions: `network load <folder>: columns=… 
sort=… needsDetails=…`, `network: names-only listing is complete …`, `hydrate: N visible
rows in Nms, N queued`, `share index: N of N rows from the index, N to fetch`, and `favorite: NetFS mount … in Nms`. Timing lines also go to
Console.app under subsystem `com.merickson.navigator`.

# Uploaded covers missing — 2026-11-09

## Confirmed cause

The cloud upload journal records 132 newly stored audio files from the batch.
FFprobe found embedded JPEG artwork in 122; Navidrome indexed artwork for the
same 122. Ten new files have no embedded artwork and no artist tags. The local
selected folder contains 162 M4A files; this report does not assume every selected
file was newly stored (the remaining upload outcomes were not fully reconstructed).

The Mac replica copied Navidrome's `item_artwork.source_path` absolute paths from
cloud (and older Android migrations), while the files live under the Mac music
root. Its library path was already local; this separate artwork table was not.
For 3AM, AEAO, Americano and other new tracks, the first Mac request returned the
exact 69,228-byte Navidrome default WebP; cloud returned real JPEG art. Mac logs
showed `stat /home/ubuntu/replica/music/...: no such file or directory` despite the
corresponding local file existing. The second request returned real JPEG art:
Navidrome had repaired the record after failing the first request.

The client rejected that known placeholder but classified it as permanently
unavailable artwork, potentially suppressing the cover for an hour. This is a
confirmed failure path; it does not establish that every blank on the user's
screen took that exact route. Cloud also logged some HTTP 429 cover responses;
those were already classified as retryable and were not reproduced in the full
post-repair check. The shared cover service is disabled (503); the client already
falls back to Navidrome, so it was not the source of missing embedded artwork.

## Repair

- Added `server/scripts/normalize_artwork_paths.py`. It rebases only literal music
  root prefixes in `item_artwork.source_path`, preserves image hashes and media,
  checks SQLite integrity, and refuses ambiguous multiple-library databases.
- Installed it in Mac operations and hooked `apply.sh` to normalize the incoming
  `.new` database before exposing it on every future replica sync. Explicit cloud
  and legacy Android roots cover historical references too.
- Took SQLite online backups before live repair. Rebased 2,451 cloud records and
  1,485 Mac records. Restarted only Mac standby Navidrome to discard its in-memory
  old path records; metadata updates alone were insufficient for cached records.
- Marked the known generic placeholder as transient. The client does not assign
  the one-hour missing-art deadline or permanently promote an external fallback
  for that response. Genuine missing-art external lookup behavior remains.
- Installed Mac and iPhone **1.1.7 (10113)** in place. Both retain ATS and embedded
  networking fixes, credentials, downloads and enrollment. Relaunch clears the
  previous in-memory missing-art suppression. No public release/tag was created.

## Verification

All 122 embedded covers returned HTTP 200 real images from **both cloud and Mac**
after repair/reload: 244 successful responses, zero placeholders, zero failures.
All batch files were present locally. The 67 cover tests passed; the strengthened
25-test cover-service subset also passed. Two path-normalizer tests cover literal
prefix matching, unchanged hashes/unrelated URLs, idempotency and multi-library
refusal. Independent review approved the final handling and deployment sequence.
The updated Mac home screen rendered artwork. Specific uploaded rows and final
phone artwork rendering were not independently navigated due automation input
errors; API verification and installation are distinct from visual verification.

Recovery databases are retained under `private/mac-replica/recovery-cover-paths/`
on Mac and `/home/ubuntu/replica/recovery-cover-paths/` on cloud (UTC stamp
`20261109T215334Z`). Previous app copies and apply script are retained as well.
Do not restore entire databases over later user writes just to revert artwork.

## Files that lack embedded artwork

- All In My Head (Flex) (feat. Fetty Wap) - Fifth Harmony
- Blue Jeans - Remastered 2011 - Lana Del Rey
- Broken - Seether, Amy Lee
- HEAVY LOVE - Odetari
- JERK! - sped up - jnhygs
- MOVE YO BODY - Bryansanon
- Partition - Homecoming Live - Beyoncé
- Sound of Madness - Shinedown
- Swimming Pool - Marie Madeleine
- WHIM WHAMIEE - PLUTO, YKNIECE

These need metadata/artwork repair. Do not place a shared cover.jpg in the flat
admin folder: that would assign one image to unrelated songs. Do not guess
artwork or retag the songs without checking the exact recordings.

## Prevent recurrence

After any host migration or replica import, check every host-specific artwork
source path, not just `library.path` and `media_file.path`. Normalize before the
first request and service startup. Test a previously unrequested cover once:
a warm second request can hide the defect. Test cloud and replica independently,
and inspect the exact placeholder hash rather than image color. A placeholder
must remain retryable; only actual absent artwork should receive a long negative
cache lifetime. Do not clear downloads or all good artwork caches as a repair.

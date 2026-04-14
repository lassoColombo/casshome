# Beets music tagging

## How beets is used in this stack

Two ConfigMaps drive beets:

| ConfigMap | Used by | `move` | Purpose |
|---|---|---|---|
| `beets-config` | `beets-import` CronJob (daily 06:00 UTC) | `false` | Tag files in-place after Lidarr drops them into `/mnt/media/music` |
| `beets-download-config` | `youtube-dl` Deployment | `true` | Tag + reorganize files downloaded via `yt-dlp` into `$albumartist/$album/$title` |

Both configs share the same library (`/music/.beets/library.blb`) and plugin set: `chroma fetchart embedart lyrics lastgenre replaygain mbsync musicbrainz`.

## Required plugins

The `musicbrainz` plugin **must be listed explicitly** in `plugins`. In beets 2.8.0, MusicBrainz became a `MetadataSourcePlugin` — an opt-in backend rather than a built-in. Without it, `metadata_plugins.album_for_id()` returns `None` for all lookups and every import falls back to `asis` regardless of AcoustID fingerprint quality or text match score.

The `mbsync` plugin syncs already-matched albums (those with an `mb_albumid`) against MusicBrainz to pick up updated metadata. It requires `musicbrainz` to be loaded to do its lookups.

## Match thresholds

Both configs are tuned for partial and YouTube-sourced imports:

```yaml
match:
  strong_rec_thresh: 0.20   # accept matches up to 80% confidence in quiet mode
  max_rec:
    missing_tracks: strong  # don't downgrade recommendation just because we have
    unmatched_tracks: strong #   fewer tracks than the MusicBrainz release lists
  va_cutoff: 1.0            # never classify an album as Various Artists
```

**`strong_rec_thresh: 0.20`** — beets' default (0.04) is calibrated for complete album imports. YouTube rips often have small duration or title differences that inflate the distance score. 0.20 accepts matches up to 80% confidence.

**`max_rec` settings** — beets caps the recommendation at `medium` when imported tracks don't cover the full MusicBrainz release. In quiet mode only `strong` recommendations auto-apply, so the cap silently blocks every partial import. Setting both to `strong` removes that floor.

**`va_cutoff: 1.0`** — beets' default (0.9) classifies an album as Various Artists if 90%+ of tracks have unique artist names. Albums with many featured guests (e.g. Jacob Collier's Djesse series, FKJ's V I N C E N T) trigger this and are excluded from quiet auto-matching. Setting to 1.0 disables VA classification entirely.

## Downloading albums from YouTube Music

The `youtube-dl` pod exposes a `download` command with two modes:

```bash
# Single track
download --single <url>

# Full album / playlist
download --album <url>

# Both flags can repeat and mix
download --single <url1> --album <url2> --single <url3>
```

### How album downloads work

yt-dlp is invoked with `--yes-playlist` and two key options:

```bash
--parse-metadata "artist:^(?P<album_artist>[^,]+)"
-o "/downloads/%(album|Unknown Album)s/%(title)s.%(ext)s"
```

**Why `--parse-metadata`:** YouTube Music embeds per-track artist strings (e.g. `Jacob Collier, Mahalia, Ty Dolla $ign`). If those vary track-to-track, beets' `group_albums: yes` splits them into separate album groups keyed by `(artist, album)`. Setting `album_artist` (TPE2) to the first artist makes the grouping key consistent across the whole album.

**Why a flat output path:** All tracks land in `/downloads/<album>/` regardless of artist. This is the directory beets scans as a single album group, so track ordering and grouping are reliable.

After yt-dlp finishes, the script runs:

```bash
beet import -q /downloads        # quiet import with MusicBrainz matching
beet mbsync                      # sync any matched albums for updated metadata
find /downloads -mindepth 1 -delete  # clean staging
```

## Tagging an artist directory manually

Use the `youtube-dl` pod — it has beets and the download config already mounted, and `move: true` so files get reorganized.

```bash
# get the pod name
kubectl get pods -n media -l app=youtube-dl

# exec in
kubectl exec -n media <pod> -- bash

# import and tag
beet -c /config/config.yaml import /music/<ArtistName>

# verify nothing needs moving (should report "X already in place")
beet -c /config/config.yaml move albumartist:"<ArtistName>"
```

## What happens per track

| Situation | Outcome |
|---|---|
| MusicBrainz text + AcoustID match with distance < 0.20 | Full metadata written: artist, album, date, track number, MusicBrainz IDs, ReplayGain, lyrics, cover art |
| Match found but distance ≥ 0.20 | `asis` fallback — existing embedded tags preserved as-is |
| No match found | `asis` fallback — beets infers title/artist from filename/path if no tags exist |

## mbsync — what it is and why it runs after import

`beet import` performs matching: it finds the best MusicBrainz release for an album and writes its metadata to the files. But the match is driven by search scores and fingerprints, so what gets written is whatever beets considered "close enough" at match time — track numbers inferred from file order, artist credits from the YouTube tags, etc.

`mbsync` is a second pass that runs after the import. It takes every album that already has an `mb_albumid` (i.e. was successfully matched), fetches the full release data from MusicBrainz by that ID, maps each track by its `mb_trackid`, and overwrites the tags with the authoritative MusicBrainz values. This corrects things like:

- Track numbers that were wrong in the embedded YouTube tags (common — YouTube embeds a playlist position, not the album track number)
- Artist credits that MusicBrainz stores differently from how they appear on YouTube (e.g. `FKJ & Carlos Santana` instead of `FKJ, Carlos Santana`)
- Any field that the initial import populated from the YouTube-embedded tags rather than from MusicBrainz directly

**mbsync cannot perform the initial match.** It only works on albums that already have `mb_albumid` set. If an album imported as-is (no match found), mbsync skips it.

In the download script the two steps run back-to-back: `import` does the matching, `mbsync` does the cleanup pass on whatever just got matched.

If a quiet import ran as-is and you know the MusicBrainz release ID, you can force a match manually:

```bash
# inside the youtube-dl pod
# 1. set the release ID (get it from musicbrainz.org or Lidarr — note: Lidarr shows the
#    release *group* ID, not the release ID; get releases from:
#    https://musicbrainz.org/ws/2/release-group/<id>?inc=releases&fmt=json)
beet -c /config/config.yaml modify -y -a mb_albumid=<release-id> albumartist:"<Artist>"

# 2. sync metadata from that release
beet -c /config/config.yaml mbsync albumartist:"<Artist>"
```

Or re-import the already-moved files to let beets re-run matching:

```bash
beet -c /config/config.yaml remove albumartist:"<Artist>"   # remove from library only (no -d)
beet -c /config/config.yaml import /music/<Artist>          # re-match with current config
```

## Re-tagging files already imported as `asis`

If a file was previously imported without a match (e.g. before the `musicbrainz` plugin was added, or before threshold tuning), force a fresh lookup:

```bash
# inside the youtube-dl pod
beet -c /config/config.yaml import --noincremental /music/<ArtistName>
# or for a single file
beet -c /config/config.yaml import --noincremental /music/<ArtistName>/<Album>/<file>.mp3
```

`--noincremental` overrides the `incremental: true` setting in `beets-config` and re-evaluates every file regardless of library state.

## Troubleshooting quiet-mode fallbacks

If beets imports everything as `asis`, run with `-v` on a single file to diagnose:

```bash
beet -c /config/config.yaml -v import /music/Artist/Album/track.mp3
```

Look for:

- No MusicBrainz candidates at all → `musicbrainz` is missing from `plugins`
- `chroma: acoustid album candidates: 0` → fingerprint not in AcoustID database; nothing to do
- `chroma: acoustid album candidates: N` + `Distance: X.XX` → match found; if X > 0.20, distance is too high; if X < 0.20 but still falling back, check `max_rec` config
- `Album might be VA: True` → `va_cutoff` is triggering; set `va_cutoff: 1.0` to disable
- `mbsync: Release ID X not found for album Y` → either the `musicbrainz` plugin is missing, or the stored `mb_albumid` is a release group ID rather than a release ID

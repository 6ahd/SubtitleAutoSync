# SubtitleAutoSync

**[العربية](README.ar.md)** · English

Automatic subtitle sync that works with **any player**.
You give it a video and an external subtitle (`.srt` `.vtt` `.ass` `.ssa`) that is out of sync; it lines the subtitle up with the timeline of a subtitle that is **already embedded in the video**, and gives you back a fixed file.

- Fixes a **constant delay** (subtitle is 3 s early or late the whole movie)
- Fixes **frame-rate mismatch** (23.976 / 24 / 25 fps: the subtitle drifts more and more)
- **Never breaks anything**: if it is not sure, it changes nothing
- Changes **only the time stamps**. Text, styling and encoding (UTF-8, Windows-1256 Arabic, GBK, UTF-16…) stay byte-for-byte the same
- Reads only the video's **index**, not the video. A 50 GB MKV takes milliseconds

```
Video (with an embedded subtitle)  ─┐
                                    ├─►  compare start times  ─►  new = old × speed + delay  ─►  fixed subtitle
External subtitle (out of sync)    ─┘                              (only if confident)
```

> **Important:** the video must contain at least one embedded subtitle track (any language, e.g. English). That track is used as the "answer key". The language doesn't matter, because only timing is compared. No embedded subtitle? You can use any correctly-timed subtitle file as the reference instead (see below).

---

## Contents

1. [I just want to fix a subtitle (any player)](#1-i-just-want-to-fix-a-subtitle-any-player)
2. [mpv: one-key sync inside the player](#2-mpv-one-key-sync-inside-the-player)
3. [Developers: add it to your player](#3-developers-add-it-to-your-player)
4. [How it works](#4-how-it-works)
5. [What's in this repo](#5-whats-in-this-repo)

---

## 1. I just want to fix a subtitle (any player)

Works for VLC, MPC-HC, PotPlayer, IINA, Kodi, Infuse, Plex, Jellyfin, a smart TV, anything that can load a subtitle file.

**Step 1: install Python 3** (free): <https://www.python.org/downloads/>
On Windows, tick **"Add Python to PATH"** during install.
For **MP4** and other non-MKV videos also install **FFmpeg** (<https://ffmpeg.org/download.html>). MKV needs nothing else.

**Step 2: download** [`python/subautosync.py`](python/subautosync.py) (one file, no dependencies).

**Step 3: run it** in a terminal (Windows: Command Prompt / PowerShell):

```bash
python3 subautosync.py "Movie.mkv" "Movie.ar.srt"
```

(On Windows use `python` instead of `python3`.)

Result:

```
✅ Synced: moved 6.5 s earlier (100% matched)
Reference: embedded track #3 eng S_TEXT/UTF8 (1243 cues)
Saved: Movie.ar.synced.srt
```

**Step 4: open `Movie.ar.synced.srt` in your player** like any subtitle.
Tip: if you rename it to exactly the video's name (`Movie.srt` or `Movie.ar.srt`) and keep it next to the video, most players (VLC, mpv, Kodi, Plex, Jellyfin, Infuse) load it automatically.

### Useful options

| Option | What it does |
|---|---|
| `-o out.srt` | choose the output file name |
| `--in-place` | overwrite the original subtitle (a `.bak` copy is kept) |
| `--lang ar` | messages in Arabic |
| `--track 3` | choose which embedded track is the reference |
| `--min-match 0.6` | be stricter (default 0.45 = 45 % of lines must match) |
| `--json` | machine-readable result (for scripts / apps) |

### No embedded subtitle in the video?

Use any subtitle you know is correctly timed for this video (for example an English one) as the reference:

```bash
python3 subautosync.py "Movie.en.srt" "Movie.ar.srt"
```

### What the messages mean

| Message | Meaning |
|---|---|
| ✅ Synced | fixed and saved |
| ✅ Already in sync | it was fine, nothing to do |
| ⚠️ Only 31 % matched | this subtitle is probably for another release of the movie |
| ⚠️ different cut | the subtitle is for another edit (director's cut, extra scene). A single shift can't fix that safely, so nothing changed |
| ⚠️ No reference | the video has no usable embedded subtitle. Use another subtitle file as the reference |

---

## 2. mpv: one-key sync inside the player

1. Copy the folder [`players/mpv/subautosync/`](players/mpv/subautosync) to your mpv `scripts` folder:
   - Windows: `%APPDATA%\mpv\scripts\subautosync\`
   - macOS / Linux: `~/.config/mpv/scripts/subautosync/`
2. Put `python/subautosync.py` **inside that same folder** (next to `main.lua`).
3. Play a video, load your subtitle, press **Ctrl+y**. The synced subtitle is loaded and selected automatically.

Optional `script-opts/subautosync.conf`:

```ini
lang=ar        # messages in Arabic
auto=yes       # sync automatically whenever you pick an external subtitle
python=python  # on Windows, if "python3" is not found
```

---

## 3. Developers: add it to your player

There are two ready-made engines with **identical results** (both tested against the same 480+ reference cases):

| You are building… | Use |
|---|---|
| iOS / tvOS / macOS / visionOS app (Swift) | the **Swift package** (this repo root) |
| Anything else (Python, Kodi add-on, server, desktop tool), or as a sidecar process | **`python/subautosync.py`** (`import subautosync` or call the CLI with `--json`) |
| Kotlin / Java / C# / JS / C++ player | port `python/subautosync.py` (~1000 lines, no dependencies) or call it as a process; the tests in `python/tests` + `Tests/.../Fixtures` tell you when your port is exact |

### The recipe (same for every player)

Whatever the platform, integration is always these 4 steps:

**1. Get the reference: start times (ms) of an embedded subtitle track.**

| Your player is based on | How to get the start times |
|---|---|
| **FFmpeg** (most custom players, KSPlayer, mpv, VLC internals, IINA) | After `avformat_find_stream_info`, call `avformat_seek_file(fmt,-1,INT64_MIN,0,INT64_MAX,0)` once **before playback** (this makes FFmpeg parse the MKV Cues), then read `avformat_index_get_entry()` for the subtitle stream. MP4: entries exist right after open; skip `mov_text` samples of size ≤ 2. Ready code: [`Integration/FFmpegSubtitleIndex.swift`](Integration/FFmpegSubtitleIndex.swift) |
| **AVPlayer / ExoPlayer / web `<video>`** (no access to the demuxer) | Read the MKV index yourself with HTTP Range requests: `MatroskaCues` + `HTTPRangeSource` (Swift) or `MatroskaCues` in the Python file. Usually 2-3 requests, < 2 MB. Pass the same auth headers you use for playback (Emby/Jellyfin/Plex token) |
| **Local files, any player** | `subautosync.load_reference(path)` (Python): MKV built-in, everything else via `ffprobe` |
| **No embedded subtitle** | use another correctly-timed subtitle file as the reference |

**2. Get the external subtitle's raw bytes** (do not decode / re-encode them).

**3. Align and decide:**

```python
import subautosync as S
ref, _ = S.load_reference("movie.mkv")              # or your own list of start times in ms
outcome = S.synchronize(sub_bytes, "movie.ar.srt", ref)
if outcome.status == "synced":
    fixed_bytes = outcome.data                       # same encoding, only times changed
print(S.describe(outcome, "ar"))                     # message for the user (ar / en)
```

**4. Apply it** (pick one):
- **Replace the subtitle** with the fixed bytes (works with every renderer, including libass), or
- **Don't touch the file**, convert the clock instead: `subtitle_time = (playback_time − offset_ms) / scale`.

### UX rules that make it feel right

- **Never make playback wait.** Show the original subtitle immediately, sync in the background, hot-swap when done.
- **Last selection wins.** If the user switches subtitles while syncing, drop the old result.
- After applying, **reset the user's manual subtitle delay to 0** (later manual tweaks still add on top).
- User-picked subtitle: always show the result message. Auto-picked: only show it when actually synced.
- Add a **"Sync current subtitle"** button in the subtitle menu.
- Turn it off for live TV / IPTV / HLS / DASH (no index to read, and IPTV often allows only one connection).
- Cache results by *subtitle hash + stable video ID* (not the URL; URLs often carry temporary tokens).

### Swift quick start

Add the package in Xcode: **File → Add Package Dependencies…** → `https://github.com/6ahd/SubtitleAutoSync`

```swift
import SubtitleAutoSync

// your player implements 4 methods:
// currentExternalSubtitleID(slot:), replaceExternalSubtitle(slot:id:data:fileName:),
// resetManualSubtitleDelay(slot:), showToast(_:)
let coordinator = AutoSyncCoordinator(player: self, language: .ar)   // .en / .ar / .zh

// 1. video opened (main thread)
coordinator.mediaDidOpen(MediaSource(url: streamURL, headers: playbackHeaders,
                                     cacheKey: "emby:\(itemId)", isLive: isLive),
                         mode: .ffmpegIndex)        // .httpRange if you have no AVFormatContext

// 2. demuxer thread, after avformat_find_stream_info, before playback (FFmpeg players only)
FFmpegSubtitleIndex.loadIndex(fmt)
let starts = FFmpegSubtitleIndex.reference(fmt)?.startsMs
Task { @MainActor in coordinator.setFFmpegReference(starts) }

// 3. an external subtitle started showing
coordinator.subtitleDidLoad(slot: 0, id: sub.id, data: sub.data, fileName: sub.fileName,
                            userInitiated: userPicked)

// 4. "Sync current subtitle" button
coordinator.syncNow(slot: 0, id: sub.id, data: sub.data, fileName: sub.fileName)
```

Only the engine, no coordinator:

```swift
let engine = SubtitleAutoSyncEngine()
let outcome = await engine.synchronize(subtitle: srtData, fileName: "movie.ar.srt",
                                       reference: ReferenceTimeline(starts: startsMs), cacheKey: "emby:123")
if case .synced(let s) = outcome {
    replaceCurrentSubtitle(with: s.data)
    showToast(s.alignment.summary(.ar))   // "تم تقديم الترجمة 6.5 ثانية (تطابق 100%)"
}
```

`Integration/FFmpegSubtitleIndex.swift` is **not** part of the package (it depends on FFmpeg): copy it into your app and replace `import CFFmpeg` with your FFmpeg module name.

Requirements: iOS 15 / tvOS 15 / macOS 12 / visionOS 1, Swift 5.9+, no dependencies.

---

## 4. How it works

Only two kinds of desync can be fixed automatically and safely, and both are a straight line: **new time = old time × speed + delay**.

1. **Reference**: start time of every line of an embedded subtitle (from the container index, no video decoding).
2. **Vote**: for 7 speeds (1, 25/23.976, 23.976/25, 25/24, 24/25, 24/23.976, 23.976/24), every subtitle line votes for "reference − subtitle" in 100 ms bins (±300 s). With the right speed almost all lines vote for the same bin, a sharp peak. The top peaks become candidates.
3. **Refine** each candidate: pair every line with the nearest reference line (≤ 350 ms), correct with the median error twice, then a least-squares fit of speed and delay.
4. **Decide**: apply only if ≥ 45 % of lines match, the result beats the best *different* solution by ≥ 20 points, and ≥ 20 lines match. A move under 250 ms counts as already in sync.
5. **Different-cut check**: the beginning, middle and end thirds are checked separately. If one third prefers another delay, the subtitle is for another edit, so nothing is changed.
6. **Rewrite** only the time stamps, keeping the original format (comma/dot, hours, ASS centiseconds) and encoding.

A 2-hour movie with 1500 lines aligns in about 10-15 ms (Swift, release build).

The full design notes (Chinese, original document) are in [`docs/design-notes.zh.md`](docs/design-notes.zh.md), including the optional audio-based fallback for videos without any embedded subtitle.

---

## 5. What's in this repo

| Path | What |
|---|---|
| `python/subautosync.py` | Single-file Python engine + command-line tool (any OS, any player) |
| `python/tests/` | Parity tests of the Python port |
| `players/mpv/` | mpv script: Ctrl+y to sync |
| `Sources/SubtitleAutoSync/` | Swift package (engine, MKV index reader, HTTP Range, coordinator, messages in en/ar/zh) |
| `Integration/FFmpegSubtitleIndex.swift` | Read reference times straight from an FFmpeg `AVFormatContext` |
| `Tests/` | Swift tests + shared fixtures (480+ reference cases, real MKV/MP4 files) |
| `docs/design-notes.zh.md` | Original design document |

### Running the tests

```bash
# Python
python3 -m unittest discover -s python/tests -v

# Swift (HTTP tests need the local Range server; they are skipped without it)
python3 Tests/Support/range_server.py Tests/SubtitleAutoSyncTests/Fixtures/media 8765 &
RANGE_SERVER_URL=http://127.0.0.1:8765 swift test
```

CI runs both on every push (macOS + Linux).

## Credits

Alignment engine ported from the DexWorld Kodi subtitle add-on (`service.subtitles.dexworld`), plus a three-segment different-cut check. Contains no code from GPL projects; NuvioTV Reshaped is only described as an idea in the design notes.

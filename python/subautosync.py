#!/usr/bin/env python3
"""
subautosync — automatic external-subtitle sync that works with ANY player.

It fixes the timing of an external subtitle (.srt / .vtt / .ass / .ssa) by
lining it up with the timeline of a subtitle that is already embedded in the
video, then writes a corrected file you can load in VLC, mpv, MPC-HC, Kodi,
PotPlayer, IINA, Infuse, Plex, Jellyfin, a TV... anything.

* Only time stamps are changed. Text, styling and the original encoding
  (UTF-8, UTF-8 BOM, UTF-16, Windows-1256, GBK, ...) stay byte-for-byte the same.
* It fixes the two kinds of desync that can be fixed safely: a constant offset
  and a frame-rate mismatch (23.976 / 24 / 25 fps).
* If it is not sure, it changes nothing.

This is a Python port of the Swift package in this repository (same algorithm,
same decisions; tested against the same fixtures). No third-party
dependencies. Python 3.8+. `ffprobe` is only needed for non-MKV videos.

Usage:
    python3 subautosync.py movie.mkv movie.ar.srt              # writes movie.ar.synced.srt
    python3 subautosync.py movie.mp4 movie.ar.srt -o out.srt   # MP4 etc. need ffprobe
    python3 subautosync.py good_timing.en.srt bad_timing.ar.srt  # use another subtitle as reference
"""
from __future__ import annotations

import argparse
import bisect
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

__version__ = "1.0.0"

SUB_EXTS = (".srt", ".vtt", ".webvtt", ".ass", ".ssa")

# ---------------------------------------------------------------------------
# 1. Subtitle timing: parse start times, rewrite time stamps (encoding-safe)
# ---------------------------------------------------------------------------

_PAIR = r"((?:\d{1,3}:)?\d{1,2}:\d{2}[,.]\d{1,3})([ \t]*-->[ \t]*)((?:\d{1,3}:)?\d{1,2}:\d{2}[,.]\d{1,3})"
_ASS = r"^(Dialogue|Comment)(:[ \t]*)([^,\r\n]*),(\d{1,2}:\d{2}:\d{2}[.:]\d{1,3}),(\d{1,2}:\d{2}:\d{2}[.:]\d{1,3}),"
_PAIR_B = re.compile(_PAIR.encode())
_ASS_B = re.compile(_ASS.encode(), re.M)
_PAIR_S = re.compile(_PAIR, re.ASCII)
_ASS_S = re.compile(_ASS, re.M | re.ASCII)


class _View:
    """Bytes are matched directly (only ASCII time stamps can match, so multi-byte
    text is never touched). UTF-16 files with a BOM are decoded and re-encoded."""

    def __init__(self, raw: bytes):
        self.raw = raw
        if raw[:2] == b"\xff\xfe":
            self.mode, self.text = "utf-16-le", raw[2:].decode("utf-16-le", "replace")
        elif raw[:2] == b"\xfe\xff":
            self.mode, self.text = "utf-16-be", raw[2:].decode("utf-16-be", "replace")
        else:
            self.mode, self.text = "bytes", raw

    def head_has_events(self) -> bool:
        h = self.text[:6000]
        return (b"[Events]" in h) if self.mode == "bytes" else ("[Events]" in h)


def detect_kind(raw: bytes, name: str = "") -> str:
    """'ass' for ASS/SSA, otherwise 'pair' (SRT, WebVTT: `start --> end`)."""
    n = name.lower()
    if n.endswith(".ass") or n.endswith(".ssa") or _View(raw).head_has_events():
        return "ass"
    return "pair"


def _regex(kind: str, mode: str):
    if kind == "ass":
        return (_ASS_B if mode == "bytes" else _ASS_S), 4, 5
    return (_PAIR_B if mode == "bytes" else _PAIR_S), 1, 3


def _s(x) -> str:
    return x.decode("ascii") if isinstance(x, bytes) else x


def timestamp_ms(raw: str) -> int:
    """`HH:MM:SS,mmm`, `MM:SS.mmm`, ASS `H:MM:SS.cc`, old ASS `H:MM:SS:cc` -> ms."""
    t = raw.replace(",", ".")
    if "." in t:
        main, frac = t.rsplit(".", 1)
    else:
        main, frac = "", t
    if main == "":
        parts = t.split(":")
        main = ":".join(parts[:3])
        frac = parts[3] if len(parts) > 3 else "0"
    nums = [int(p) if p.isdigit() else 0 for p in main.split(":")]
    while len(nums) < 3:
        nums.insert(0, 0)
    h, m, s = nums[-3], nums[-2], nums[-1]
    ms = int((frac + "000")[:3]) if frac else 0
    return ((h * 60 + m) * 60 + s) * 1000 + ms


def format_ts(ms: int, like: str, kind: str) -> str:
    """Write ms the same way the original stamp was written (comma/dot, with/without hours)."""
    ms = max(0, ms)
    h, rem = divmod(ms, 3_600_000)
    m, rem = divmod(rem, 60_000)
    s, x = divmod(rem, 1000)
    if kind == "ass":
        cs = round(x / 10.0)
        if cs == 100:
            return format_ts(ms + 5, like, kind)
        return f"{h}:{m:02d}:{s:02d}.{cs:02d}"
    sep = "," if "," in like else "."
    if like.count(":") >= 2 or h > 0:
        return f"{h:02d}:{m:02d}:{s:02d}{sep}{x:03d}"
    return f"{m:02d}:{s:02d}{sep}{x:03d}"


def parse_starts(raw: bytes, name: str = "") -> List[int]:
    """Start time (ms) of every cue. ASS: Dialogue only (Comment skipped)."""
    kind = detect_kind(raw, name)
    v = _View(raw)
    rx, ga, gb = _regex(kind, v.mode)
    out = []
    for m in rx.finditer(v.text):
        if kind == "ass" and _s(m.group(1)) != "Dialogue":
            continue
        a, b = timestamp_ms(_s(m.group(ga))), timestamp_ms(_s(m.group(gb)))
        if b >= a:
            out.append(a)
    return sorted(out)


def apply_transform(raw: bytes, scale: float, offset_ms: int, name: str = "") -> bytes:
    """new = old * scale + offset_ms for every time stamp; everything else unchanged."""
    kind = detect_kind(raw, name)
    v = _View(raw)
    rx, ga, gb = _regex(kind, v.mode)

    def conv(t: str) -> int:
        return max(0, int(round(timestamp_ms(t) * scale + offset_ms)))

    pieces = []
    last = 0
    enc = (lambda s: s.encode("ascii")) if v.mode == "bytes" else (lambda s: s)
    for m in rx.finditer(v.text):
        a0, b0 = _s(m.group(ga)), _s(m.group(gb))
        na = conv(a0)
        nb = max(na + 1, conv(b0))
        pieces.append(v.text[last:m.start(ga)])
        pieces.append(enc(format_ts(na, a0, kind)))
        pieces.append(v.text[m.end(ga):m.start(gb)])
        pieces.append(enc(format_ts(nb, b0, kind)))
        last = m.end(gb)
    pieces.append(v.text[last:])
    if v.mode == "bytes":
        return b"".join(pieces)
    bom = b"\xff\xfe" if v.mode == "utf-16-le" else b"\xfe\xff"
    return bom + "".join(pieces).encode(v.mode, "surrogatepass")


# ---------------------------------------------------------------------------
# 2. Alignment (time only, text is never read)
# ---------------------------------------------------------------------------

SCALES = [1.0, 25 / 23.976, 23.976 / 25, 25 / 24, 24 / 25, 24 / 23.976, 23.976 / 24]


@dataclass
class Alignment:
    scale: float = 1.0
    offset_ms: int = 0
    matched: float = 0.0
    rival: float = 0.0
    hits: int = 0
    total: int = 0
    max_move_ms: int = 0
    reason: Optional[str] = None


def _dedupe(xs: Sequence[int], gap: int = 40) -> List[int]:
    out: List[int] = []
    for x in sorted(xs):
        if not out or x - out[-1] > gap:
            out.append(x)
    return out


def _match(ref: List[int], sub: List[int], scale: float, off: float, tol: float):
    pairs = []
    j, n = 0, len(ref)
    for s in sub:
        x = s * scale + off
        while j + 1 < n and ref[j + 1] <= x:
            j += 1
        best = None
        for k in (j, j + 1):
            if 0 <= k < n:
                d = ref[k] - x
                if best is None or abs(d) < abs(best[2]):
                    best = (s, ref[k], d)
        if best is not None and abs(best[2]) <= tol:
            pairs.append(best)
    return pairs


def _median(v: List[float]) -> float:
    if not v:
        return 0.0
    s = sorted(v)
    return s[len(s) // 2]


def _fit(pairs):
    n = len(pairs)
    if n < 20:
        return None
    mx = sum(p[0] for p in pairs) / n
    my = sum(p[1] for p in pairs) / n
    vxx = 0.0
    for p in pairs:
        dx = p[0] - mx
        vxx += dx * dx
    if vxx <= 0:
        return None
    cov = 0.0
    for p in pairs:
        cov += (p[0] - mx) * (p[1] - my)
    a = cov / vxx
    return a, my - a * mx


def _refine(ref, sub, scale, off, tol):
    pairs = _match(ref, sub, scale, off, tol)
    for _ in range(2):
        if not pairs:
            break
        off += _median([p[2] for p in pairs])
        pairs = _match(ref, sub, scale, off, tol)
    f = _fit(pairs)
    if f is not None and 0.94 <= f[0] <= 1.07:
        p2 = _match(ref, sub, f[0], f[1], tol)
        if len(p2) >= len(pairs):
            scale, off, pairs = f[0], f[1], p2
            if pairs:
                off += _median([p[2] for p in pairs])
                pairs = _match(ref, sub, scale, off, tol)
    return scale, off, pairs


def _peaks(refd, points, scale, base_off, max_offset_ms):
    """100 ms histogram of (reference - subtitle) differences, smoothed over 3 bins."""
    r = max_offset_ms // 100
    hist = [0] * (2 * r + 3)
    for s in points:
        x = s * scale + base_off
        lo = bisect.bisect_left(refd, x - max_offset_ms)
        hi = bisect.bisect_right(refd, x + max_offset_ms)
        for k in range(lo, hi):
            hist[int((refd[k] - x) / 100.0 + r + 1.5)] += 1
    sm = [hist[k - 1] + hist[k] + hist[k + 1] for k in range(1, len(hist) - 1)]
    order = sorted(range(len(sm)), key=lambda k: (-sm[k], k))
    return r, sm, order


def align(ref_starts: Sequence[int], sub_starts: Sequence[int], max_offset_ms: int = 300_000,
          tolerance_ms: float = 350, sample: int = 400) -> Alignment:
    ref, sub = _dedupe(ref_starts), _dedupe(sub_starts)
    res = Alignment(total=len(sub))
    if len(ref) < 30 or len(sub) < 30:
        res.reason = "too_few_lines"
        return res
    step = max(1, len(sub) // sample)
    votes = sub[::step]
    refd = [float(x) for x in ref]
    cands: List[Tuple[float, float]] = [(1.0, 0.0)]
    for sc in SCALES:
        r, sm, order = _peaks(refd, votes, sc, 0.0, max_offset_ms)
        taken: List[int] = []
        for k in order:
            if len(taken) >= 4 or sm[k] <= 0:
                break
            if all(abs(k - t) > 10 for t in taken):
                taken.append(k)
                cands.append((sc, (k - r) * 100.0))
    scored = []
    for i, (sc, o) in enumerate(cands):
        s2, o2, pairs = _refine(ref, sub, sc, o, tolerance_ms)
        scored.append((len(pairs), s2, o2, i))
    scored.sort(key=lambda t: (-t[0], t[3]))
    best = scored[0]
    probes = [float(sub[0]), float(sub[len(sub) // 2]), float(sub[-1])]

    def moved(sc, o, sc2, o2):
        return max(abs((p * sc + o) - (p * sc2 + o2)) for p in probes)

    rival = 0
    for c in scored[1:]:
        if moved(c[1], c[2], best[1], best[2]) > 1500:
            rival = c[0]
            break
    total = float(len(sub))
    res.scale = best[1]
    res.offset_ms = int(round(best[2]))
    res.hits = best[0]
    res.matched = best[0] / total
    res.rival = rival / total
    res.max_move_ms = int(round(moved(best[1], best[2], 1.0, 0.0)))
    return res


def decide(res: Alignment, min_match: float = 0.45, min_margin: float = 0.2,
           min_hits: int = 20, noop_ms: int = 250) -> str:
    """'sync' (apply), 'in_sync' (already fine) or 'unsure' (leave alone)."""
    if res.reason:
        return "unsure"
    strong = res.matched >= min_match and (res.matched - res.rival) >= min_margin and res.hits >= min_hits
    if not strong:
        return "unsure"
    return "in_sync" if res.max_move_ms < noop_ms else "sync"


def segment_check(ref_starts, sub_starts, res: Alignment, tolerance_ms=350, max_offset_ms=300_000,
                  exclude_ms=1000, margin=0.10, floor=0.30, min_lines=10):
    """Front / middle / end must agree on the same transform. If one third fits a
    different offset about as well, the subtitle is for a different cut: reject.
    Returns (ok, [(global, best_other, disagrees) | None] * 3)."""
    ref, sub = _dedupe(ref_starts), _dedupe(sub_starts)
    if not sub or not ref:
        return True, []
    sc, off = res.scale, float(res.offset_ms)
    a, b = sub[0], sub[-1]
    span = float(b - a)
    refd = [float(x) for x in ref]
    segs = []
    for i in range(3):
        lo = a + span * i / 3.0
        hi = a + span * (i + 1) / 3.0
        part = [s for s in sub if lo <= s and (s < hi or (i == 2 and s <= hi))]
        if len(part) < min_lines:
            segs.append(None)
            continue
        n = float(len(part))
        g = len(_match(ref, part, sc, off, tolerance_ms)) / n
        r, sm, order = _peaks(refd, part, sc, off, max_offset_ms)
        taken: List[int] = []
        best = 0.0
        for k in order:
            if len(taken) >= 3 or sm[k] <= 0:
                break
            shift = (k - r) * 100.0
            if abs(shift) <= exclude_ms:
                continue
            if all(abs(k - t) > 10 for t in taken):
                taken.append(k)
                pairs = _match(ref, part, sc, off + shift, tolerance_ms)
                if pairs:
                    shift2 = shift + _median([p[2] for p in pairs])
                    pairs = _match(ref, part, sc, off + shift2, tolerance_ms) if abs(shift2) > exclude_ms else []
                best = max(best, len(pairs) / n)
        segs.append((g, best, best >= max(floor, g - margin)))
    return (not any(s and s[2] for s in segs)), segs


# ---------------------------------------------------------------------------
# 3. Reference timeline from the video
# ---------------------------------------------------------------------------

class ReferenceError_(Exception):
    def __init__(self, reason: str, detail: str = ""):
        super().__init__(f"{reason}: {detail}" if detail else reason)
        self.reason, self.detail = reason, detail


@dataclass
class Track:
    number: int
    codec: str
    name: str = ""
    lang: str = ""
    is_default: bool = True
    forced: bool = False
    hi: bool = False
    commentary: bool = False
    is_image: bool = False
    starts: List[int] = field(default_factory=list)

    def describe(self) -> str:
        return f"#{self.number} {self.lang or '?'} {self.codec} ({len(self.starts)} cues)"


class _Budget:
    def __init__(self, max_bytes=24 << 20, max_requests=16):
        self.max_bytes, self.max_requests, self.bytes, self.requests = max_bytes, max_requests, 0, 0


class _FileSource:
    def __init__(self, path: str, budget: _Budget):
        self.f = open(path, "rb")
        self.size = os.fstat(self.f.fileno()).st_size
        self.budget = budget

    def read(self, pos: int, length: int, partial_ok: bool = True) -> bytes:
        if pos >= self.size:
            return b""
        length = min(length, self.size - pos)
        if length <= 0:
            return b""
        b = self.budget
        if b.requests + 1 > b.max_requests:
            raise ReferenceError_("budget_requests")
        room = b.max_bytes - b.bytes
        if room <= 0 or (not partial_ok and length > room):
            raise ReferenceError_("budget_bytes")
        b.requests += 1
        self.f.seek(pos)
        data = self.f.read(min(length, room))
        b.bytes += len(data)
        return data

    def close(self):
        self.f.close()


class MatroskaCues:
    """Read only the MKV index (Cues): start time of every embedded subtitle line.
    Never touches video data; typically 2-3 reads and < 2 MB even for a 50 GB file."""

    EBML, DOCTYPE, SEGMENT = 0x1A45DFA3, 0x4282, 0x18538067
    SEEKHEAD, SEEK, SEEKID, SEEKPOS = 0x114D9B74, 0x4DBB, 0x53AB, 0x53AC
    INFO, TSCALE = 0x1549A966, 0x2AD7B1
    TRACKS, ENTRY, TNUM, TTYPE, CODEC, NAME = 0x1654AE6B, 0xAE, 0xD7, 0x83, 0x86, 0x536E
    LANG, BCP47, FDEF, FFORCED, FHI, FCOMM = 0x22B59C, 0x22B59D, 0x88, 0x55AA, 0x55AB, 0x55AF
    CUES, CUEPOINT, CUETIME, CUEPOS, CUETRACK, CUEDUR, CLUSTER = (
        0x1C53BB6B, 0xBB, 0xB3, 0xB7, 0xF7, 0xB2, 0x1F43B675)
    MB = 1 << 20

    def __init__(self, src: _FileSource):
        self.src = src
        self.head_bytes, self.chunk = 512 << 10, 1 << 20
        self.caps = {self.CUES: 16 << 20, self.TRACKS: 4 << 20, self.SEEKHEAD: 2 << 20, self.INFO: 512 << 10}
        self.via = None

    # --- EBML primitives
    @staticmethod
    def _vlen(b: int) -> int:
        if b == 0:
            return 0
        n, mask = 1, 0x80
        while not b & mask:
            mask >>= 1
            n += 1
        return n

    @classmethod
    def header(cls, buf: bytes, pos: int, end: int):
        """-> (id, data_start, data_end | None, pos) or None"""
        if pos >= end:
            return None
        il = cls._vlen(buf[pos])
        if il == 0 or il > 4 or pos + il > end:
            return None
        eid = int.from_bytes(buf[pos:pos + il], "big")
        p = pos + il
        if p >= end:
            return None
        sl = cls._vlen(buf[p])
        if sl == 0 or sl > 8 or p + sl > end:
            return None
        fm = 0 if sl >= 8 else (0xFF >> sl)
        size = buf[p] & fm
        unknown = size == fm
        for i in range(1, sl):
            size = (size << 8) | buf[p + i]
            if buf[p + i] != 0xFF:
                unknown = False
        ds = p + sl
        return eid, ds, (None if unknown else ds + size), pos

    @classmethod
    def children(cls, buf, start, end):
        out, p = [], start
        while p < end:
            h = cls.header(buf, p, end)
            if h is None or h[2] is None or h[2] > end:
                break
            out.append(h)
            p = h[2]
        return out

    @staticmethod
    def _u(buf, s, e) -> int:
        return int.from_bytes(buf[s:e], "big") if e > s else 0

    @staticmethod
    def _str(buf, s, e) -> str:
        return buf[s:e].decode("utf-8", "replace").rstrip("\x00")

    def _element(self, head: bytes, at: int, expect: int):
        cap = self.caps[expect]
        if at + 12 <= len(head):
            h = self.header(head, at, len(head))
            if h and h[0] == expect and h[2] is not None and h[2] <= len(head):
                return head, h
        if at >= self.src.size:
            return None
        first = self.src.read(at, min(self.chunk, cap + 16), True)
        h = self.header(first, 0, len(first))
        if h is None or h[0] != expect:
            return None
        if h[2] is None:
            raise ReferenceError_("unknown_size", hex(expect))
        if h[2] > cap + 16:
            raise ReferenceError_("cues_too_large" if expect == self.CUES else "element_too_large",
                                  f"{h[2] / self.MB:.1f}MB")
        if h[2] <= len(first):
            return first, h
        buf = first + self.src.read(at + len(first), h[2] - len(first), False)
        if h[2] > len(buf):
            raise ReferenceError_("truncated", hex(expect))
        return buf, h

    def load(self) -> List[Track]:
        try:
            return self._load()
        finally:
            self.src.close()

    def _load(self) -> List[Track]:
        head = self.src.read(0, self.head_bytes, True)
        if len(head) < 32:
            raise ReferenceError_("short_file")
        e = self.header(head, 0, len(head))
        if not e or e[0] != self.EBML or e[2] is None or e[2] > len(head):
            raise ReferenceError_("not_mkv")
        doctype = "matroska"
        for c in self.children(head, e[1], e[2]):
            if c[0] == self.DOCTYPE:
                doctype = self._str(head, c[1], c[2])
        if doctype.lower() not in ("matroska", "webm"):
            raise ReferenceError_("not_mkv", doctype)
        p, seg = e[2], None
        while p < len(head):
            h = self.header(head, p, len(head))
            if h is None:
                break
            if h[0] == self.SEGMENT:
                seg = h
                break
            if h[2] is None:
                break
            p = h[2]
        if seg is None:
            raise ReferenceError_("no_segment")
        seg_start = seg[1]
        pos: Dict[int, int] = {}
        p = seg_start
        while p < len(head):
            h = self.header(head, p, len(head))
            if h is None:
                break
            if h[0] in (self.SEEKHEAD, self.INFO, self.TRACKS, self.CUES) and h[0] not in pos:
                pos[h[0]] = h[3]
            if h[0] == self.CLUSTER or h[2] is None:
                break
            p = h[2]
        queue = [pos[self.SEEKHEAD]] if self.SEEKHEAD in pos else []
        seen, hops = set(), 0
        while queue and hops < 4:
            at = queue.pop(0)
            if at in seen:
                continue
            seen.add(at)
            hops += 1
            try:
                el = self._element(head, at, self.SEEKHEAD)
            except ReferenceError_ as err:
                if err.reason in ("budget_bytes", "budget_requests"):
                    raise
                el = None
            if not el:
                continue
            buf, h = el
            for s in self.children(buf, h[1], h[2]):
                if s[0] != self.SEEK:
                    continue
                sid = spos = None
                for c in self.children(buf, s[1], s[2]):
                    if c[0] == self.SEEKID:
                        sid = self._u(buf, c[1], c[2])
                    elif c[0] == self.SEEKPOS:
                        spos = self._u(buf, c[1], c[2])
                if sid is None or spos is None:
                    continue
                ab = seg_start + spos
                if sid == self.SEEKHEAD:
                    if ab not in seen:
                        queue.append(ab)
                elif sid not in pos:
                    pos[sid] = ab
        scale = 1_000_000
        if self.INFO in pos:
            el = self._element(head, pos[self.INFO], self.INFO)
            if el:
                buf, h = el
                for c in self.children(buf, h[1], h[2]):
                    if c[0] == self.TSCALE:
                        scale = self._u(buf, c[1], c[2]) or 1_000_000
        if self.TRACKS not in pos:
            raise ReferenceError_("no_tracks")
        el = self._element(head, pos[self.TRACKS], self.TRACKS)
        if not el:
            raise ReferenceError_("no_tracks")
        raw_tracks = self._tracks(*el)
        subs = [t for t in raw_tracks if t["type"] == 17]
        usable = [t for t in subs if is_text_codec(t["codec"]) or is_image_codec(t["codec"])]
        if not subs:
            raise ReferenceError_("no_subtitle_tracks")
        if not usable:
            raise ReferenceError_("no_usable_subtitles", ",".join(sorted({t["codec"] for t in subs})))
        cmap = self._cues(head, pos, {t["number"] for t in usable})
        out = []
        for t in usable:
            ticks = sorted({x for x in cmap.get(t["number"], [])})
            starts = [int(round(x * scale / 1e6)) for x in ticks]
            out.append(Track(number=t["number"], codec=t["codec"], name=t["name"],
                             lang=track_lang(t["language"], t["bcp47"]), is_default=t["default"],
                             forced=t["forced"], hi=t["hi"], commentary=t["commentary"],
                             is_image=not is_text_codec(t["codec"]), starts=starts))
        return out

    def _tracks(self, buf, h):
        out = []
        for e in self.children(buf, h[1], h[2]):
            if e[0] != self.ENTRY:
                continue
            t = dict(number=None, type=None, codec="", name="", language="eng", bcp47="",
                     default=True, forced=False, hi=False, commentary=False)
            for c in self.children(buf, e[1], e[2]):
                i, s, en = c[0], c[1], c[2]
                if i == self.TNUM:
                    t["number"] = self._u(buf, s, en)
                elif i == self.TTYPE:
                    t["type"] = self._u(buf, s, en)
                elif i == self.CODEC:
                    t["codec"] = self._str(buf, s, en)
                elif i == self.NAME:
                    t["name"] = self._str(buf, s, en)
                elif i == self.LANG:
                    t["language"] = self._str(buf, s, en) or "eng"
                elif i == self.BCP47:
                    t["bcp47"] = self._str(buf, s, en)
                elif i == self.FDEF:
                    t["default"] = self._u(buf, s, en) != 0
                elif i == self.FFORCED:
                    t["forced"] = self._u(buf, s, en) == 1
                elif i == self.FHI:
                    t["hi"] = self._u(buf, s, en) == 1
                elif i == self.FCOMM:
                    t["commentary"] = self._u(buf, s, en) == 1
            if t["number"] is not None:
                out.append(t)
        return out

    def _parse_cues(self, buf, h, want) -> Dict[int, List[int]]:
        out: Dict[int, List[int]] = {n: [] for n in want}
        for cp in self.children(buf, h[1], h[2]):
            if cp[0] != self.CUEPOINT:
                continue
            t, tracks = None, []
            for c in self.children(buf, cp[1], cp[2]):
                if c[0] == self.CUETIME:
                    t = self._u(buf, c[1], c[2])
                elif c[0] == self.CUEPOS:
                    for x in self.children(buf, c[1], c[2]):
                        if x[0] == self.CUETRACK:
                            tn = self._u(buf, x[1], x[2])
                            if tn in want:
                                tracks.append(tn)
            if t is not None:
                for tn in tracks:
                    out[tn].append(t)
        return out

    def _cues(self, head, pos, want):
        if self.CUES in pos:
            try:
                el = self._element(head, pos[self.CUES], self.CUES)
            except ReferenceError_ as err:
                if err.reason in ("budget_bytes", "budget_requests", "cues_too_large"):
                    raise
                el = None
            if el:
                self.via = "seekhead"
                return self._parse_cues(el[0], el[1], want)
        size = self.src.size
        if size <= len(head):
            raise ReferenceError_("no_cues")
        start = max(0, size - (4 << 20))
        tail = self.src.read(start, size - start, True)
        magic = b"\x1c\x53\xbb\x6b"
        end = len(tail)
        while True:
            i = tail.rfind(magic, 0, end)
            if i < 0:
                break
            h = self.header(tail, i, len(tail))
            if h and h[2] is not None and h[2] <= len(tail):
                c = self.header(tail, h[1], h[2])
                if c and c[0] == self.CUEPOINT:
                    m = self._parse_cues(tail, h, want)
                    if sum(len(v) for v in m.values()):
                        self.via = "tail"
                        return m
            end = i
        raise ReferenceError_("no_cues")


def is_text_codec(c: str) -> bool:
    c = c.upper()
    return c.startswith("S_TEXT/") or c in ("S_ASS", "S_SSA") or c.startswith("D_WEBVTT")


def is_image_codec(c: str) -> bool:
    c = c.upper()
    return c.startswith("S_HDMV/PGS") or c.startswith("S_VOBSUB") or c.startswith("S_DVBSUB")


_TWO = {"en": "eng", "ar": "ara", "fr": "fra", "de": "deu", "es": "spa", "it": "ita", "pt": "por",
        "tr": "tur", "ru": "rus", "ja": "jpn", "ko": "kor", "zh": "zho", "nl": "nld"}
_B2T = {"fre": "fra", "ger": "deu", "dut": "nld", "chi": "zho", "per": "fas", "gre": "ell",
        "cze": "ces", "rum": "ron"}


def norm_lang(x: str) -> str:
    s = (x or "").strip().lower().replace("_", "-").split("-")[0]
    if s in ("", "und", "unknown", "mis", "zxx"):
        return ""
    if len(s) == 2:
        return _TWO.get(s, s)
    return _B2T.get(s, s)


def track_lang(language: str, bcp47: str) -> str:
    return norm_lang(bcp47) or norm_lang(language)


def pick_reference(tracks: List[Track], duration_ms: Optional[int] = None, min_cues: int = 30,
                   min_span_ms: int = 120_000, min_coverage: float = 0.5) -> Optional[Track]:
    """Text before image; English first; forced/commentary last; SRT over ASS; SDH slightly lower; more lines first.
    The language of the reference does not matter for the result (only times are compared)."""
    def usable(t: Track) -> bool:
        need = min_cues * (2 if t.is_image else 1)
        if len(t.starts) < need:
            return False
        span = t.starts[-1] - t.starts[0]
        if duration_ms and span < duration_ms * min_coverage:
            return False
        return span >= min_span_ms

    def score(t: Track) -> float:
        s = 0.0 if t.lang == "eng" else 5.0
        s += 50 if t.forced else 0
        s += 50 if t.commentary else 0
        c = t.codec.upper()
        s += 2 if ("ASS" in c or "SSA" in c) else 0
        s += 1 if t.hi else 0
        return s - min(len(t.starts), 3000) / 1000.0

    for image in (False, True):
        pool = [(i, t) for i, t in enumerate(tracks) if t.is_image == image and usable(t)]
        if pool:
            return min(pool, key=lambda it: (score(it[1]), it[0]))[1]
    return None


def mkv_tracks(path: str) -> List[Track]:
    return MatroskaCues(_FileSource(path, _Budget())).load()


def ffprobe_tracks(path: str) -> Tuple[List[Track], Optional[int]]:
    """Any container FFmpeg can open (MP4, MKV, M2TS, ...). Reads packet times of each subtitle stream."""
    exe = shutil.which("ffprobe")
    if not exe:
        raise ReferenceError_("no_ffprobe", "install FFmpeg (ffprobe) for non-MKV videos")
    info = json.loads(subprocess.run(
        [exe, "-v", "error", "-show_entries",
         "format=duration,start_time:stream=index,codec_type,codec_name:stream_tags=language,title"
         ":stream_disposition=default,forced,hearing_impaired,comment",
         "-of", "json", path], capture_output=True, check=True).stdout or b"{}")
    fmt = info.get("format", {})
    t0 = float(fmt.get("start_time") or 0)
    dur = int(float(fmt["duration"]) * 1000) if fmt.get("duration") else None
    out = []
    image_codecs = {"hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"}
    for st in info.get("streams", []):
        if st.get("codec_type") != "subtitle":
            continue
        idx, codec = st["index"], st.get("codec_name", "")
        tags, disp = st.get("tags", {}), st.get("disposition", {})
        pk = subprocess.run([exe, "-v", "error", "-select_streams", str(idx), "-show_entries",
                             "packet=pts_time,size", "-of", "csv=p=0", path],
                            capture_output=True, check=True).stdout.decode("ascii", "replace")
        empty = 2 if codec == "mov_text" else (8 if codec == "webvtt" and path.lower().endswith((".mp4", ".m4v", ".mov")) else -1)
        starts = []
        for line in pk.splitlines():
            parts = line.strip().split(",")
            if len(parts) < 2 or parts[0] in ("", "N/A"):
                continue
            try:
                t, size = float(parts[0]), int(parts[1])
            except ValueError:
                continue
            if size <= empty:
                continue
            starts.append(int(round((t - t0) * 1000)))
        out.append(Track(number=idx, codec=codec, name=tags.get("title", ""), lang=norm_lang(tags.get("language", "")),
                         is_default=bool(disp.get("default")), forced=bool(disp.get("forced")),
                         hi=bool(disp.get("hearing_impaired")), commentary=bool(disp.get("comment")),
                         is_image=codec in image_codecs, starts=sorted(set(starts))))
    return out, dur


def load_reference(path: str, track: Optional[int] = None) -> Tuple[List[int], str]:
    """Reference start times from a video (embedded subtitles) or from a subtitle file."""
    if path.lower().endswith(SUB_EXTS):
        with open(path, "rb") as f:
            starts = parse_starts(f.read(), path)
        return starts, f"subtitle file {os.path.basename(path)} ({len(starts)} cues)"
    tracks: List[Track] = []
    duration = None
    err: Optional[ReferenceError_] = None
    try:
        tracks = mkv_tracks(path)
    except ReferenceError_ as e:
        err = e
    except OSError as e:
        raise ReferenceError_("io_error", str(e))
    if err is not None or not pick_reference(tracks):
        if shutil.which("ffprobe"):
            try:
                tracks, duration = ffprobe_tracks(path)
            except subprocess.CalledProcessError as e:
                raise ReferenceError_("ffprobe_failed", e.stderr.decode(errors="replace")[:200])
        elif err is not None:
            if err.reason == "not_mkv":
                raise ReferenceError_("not_mkv", "install FFmpeg (ffprobe) for MP4 and other formats")
            raise err
    if track is not None:
        chosen = next((t for t in tracks if t.number == track), None)
        if chosen is None:
            raise ReferenceError_("no_such_track", str(track))
    else:
        chosen = pick_reference(tracks, duration)
    if chosen is None:
        raise ReferenceError_("no_usable_text_track",
                              " ".join(f"{t.lang or '?'}:{len(t.starts)}" for t in tracks) or "no subtitle tracks")
    return chosen.starts, "embedded track " + chosen.describe()


# ---------------------------------------------------------------------------
# 4. One-call API + messages
# ---------------------------------------------------------------------------

@dataclass
class Outcome:
    status: str          # synced | in_sync | unsure | different_cut | too_few_lines | no_reference
    alignment: Optional[Alignment] = None
    data: Optional[bytes] = None
    reason: str = ""
    lines: int = 0


def synchronize(subtitle: bytes, file_name: str, reference: Sequence[int], min_match: float = 0.45,
                segment_check_enabled: bool = True, min_lines: int = 30) -> Outcome:
    starts = parse_starts(subtitle, file_name)
    if len(starts) < min_lines:
        return Outcome("too_few_lines", lines=len(starts))
    res = align(reference, starts)
    d = decide(res, min_match)
    if d == "in_sync":
        return Outcome("in_sync", res)
    if d == "unsure":
        return Outcome("unsure", res)
    if segment_check_enabled:
        ok, _ = segment_check(reference, starts, res)
        if not ok:
            return Outcome("different_cut", res)
    return Outcome("synced", res, apply_transform(subtitle, res.scale, res.offset_ms, file_name))


def _fps_pair(scale: float) -> Optional[str]:
    names = [(25 / 23.976, "23.976 ↔ 25"), (25 / 24, "24 ↔ 25"), (24 / 23.976, "23.976 ↔ 24")]
    best = min((min(abs(scale - v), abs(scale - 1 / v)), n) for v, n in names)
    return best[1] if best[0] < 0.002 else None


def describe(o: Outcome, lang: str = "en", min_match: float = 0.45) -> str:
    ar = lang == "ar"
    r = o.alignment
    pct = lambda x: int(round(x * 100))
    if o.status == "synced":
        assert r is not None
        if abs(r.scale - 1) > 0.0005:
            pair = _fps_pair(r.scale)
            if pair:
                ch = f"تم تصحيح فرق معدل الإطارات {pair}" if ar else f"fixed frame-rate mismatch {pair} fps"
            else:
                ch = f"تم تصحيح فرق السرعة ({(r.scale - 1) * 100:.2f}%)" if ar else f"fixed speed difference ({(r.scale - 1) * 100:.2f}%)"
            if abs(r.offset_ms) >= 250:
                sec = f"{abs(r.offset_ms) / 1000:.1f}"
                ch += (f" وإزاحة {sec} ثانية" if ar else f" and shifted {sec} s")
        else:
            sec = f"{abs(r.offset_ms) / 1000:.1f}"
            if ar:
                ch = f"تم تقديم الترجمة {sec} ثانية" if r.offset_ms < 0 else f"تم تأخير الترجمة {sec} ثانية"
            else:
                ch = f"moved {sec} s earlier" if r.offset_ms < 0 else f"moved {sec} s later"
        return (f"✅ تمت المزامنة: {ch} (تطابق {pct(r.matched)}%)" if ar
                else f"✅ Synced: {ch} ({pct(r.matched)}% matched)")
    if o.status == "in_sync":
        return (f"✅ الترجمة متزامنة أصلاً (تطابق {pct(r.matched)}%)، لم يتغير شيء" if ar
                else f"✅ Already in sync ({pct(r.matched)}% matched), nothing changed")
    if o.status == "unsure":
        if r is None or r.hits == 0:
            return "⚠️ الترجمة لا تطابق الفيديو، لم يتغير شيء" if ar else "⚠️ Subtitle does not match this video, nothing changed"
        if r.matched < min_match:
            return (f"⚠️ التطابق {pct(r.matched)}% فقط (المطلوب {pct(min_match)}%)، غالباً ترجمة لنسخة أخرى. لم يتغير شيء" if ar
                    else f"⚠️ Only {pct(r.matched)}% matched (need {pct(min_match)}%), probably for another release. Nothing changed")
        return (f"⚠️ التطابق {pct(r.matched)}% لكن النتيجة غير حاسمة، لم يتغير شيء" if ar
                else f"⚠️ {pct(r.matched)}% matched but the result is ambiguous, nothing changed")
    if o.status == "different_cut":
        return ("⚠️ الترجمة لنسخة مونتاج مختلفة (جزء من الفيلم لا يطابق)، لم يتغير شيء" if ar
                else "⚠️ Subtitle is for a different cut (one part of the film does not match), nothing changed")
    if o.status == "too_few_lines":
        return (f"⚠️ الترجمة فيها {o.lines} سطر فقط، غير كافية للمزامنة التلقائية" if ar
                else f"⚠️ Subtitle has only {o.lines} lines, not enough for auto-sync")
    reasons_ar = {"not_mkv": "الفيديو ليس MKV، ثبّت FFmpeg (ffprobe) لدعم MP4 والصيغ الأخرى",
                  "no_ffprobe": "ثبّت FFmpeg (ffprobe) لدعم هذه الصيغة",
                  "no_subtitle_tracks": "لا توجد ترجمة مدمجة في الفيديو لتكون مرجعاً",
                  "no_usable_subtitles": "الترجمة المدمجة في الفيديو لا تصلح مرجعاً",
                  "no_usable_text_track": "الترجمة المدمجة قليلة جداً أو لا تصلح مرجعاً",
                  "no_cues": "فهرس الفيديو غير موجود أو ناقص"}
    reasons_en = {"not_mkv": "video is not MKV; install FFmpeg (ffprobe) for MP4 and other formats",
                  "no_ffprobe": "install FFmpeg (ffprobe) for this format",
                  "no_subtitle_tracks": "the video has no embedded subtitle to use as reference",
                  "no_usable_subtitles": "the embedded subtitles cannot be used as reference",
                  "no_usable_text_track": "the embedded subtitles are too short or unusable as reference",
                  "no_cues": "the video index is missing or incomplete"}
    txt = (reasons_ar if ar else reasons_en).get(o.reason, o.reason)
    return f"⚠️ {txt}. لم يتغير شيء" if ar else f"⚠️ No reference: {txt}. Nothing changed"


# ---------------------------------------------------------------------------
# 5. Command line
# ---------------------------------------------------------------------------

def _default_out(sub_path: str) -> str:
    base, ext = os.path.splitext(sub_path)
    return f"{base}.synced{ext}"


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(
        prog="subautosync",
        description="Auto-sync an external subtitle to a video (works with any player). "
                    "مزامنة تلقائية لملف ترجمة خارجي مع الفيديو (تعمل مع أي مشغل).")
    ap.add_argument("reference", help="video file (MKV built-in; MP4/others need ffprobe) or a correctly-timed subtitle")
    ap.add_argument("subtitle", help="subtitle to fix (.srt .vtt .ass .ssa)")
    ap.add_argument("-o", "--output", help="output file (default: <subtitle>.synced.<ext>)")
    ap.add_argument("--in-place", action="store_true", help="overwrite the subtitle (a .bak copy is kept)")
    ap.add_argument("--track", type=int, help="embedded subtitle track to use as reference (MKV track number / ffprobe stream index)")
    ap.add_argument("--min-match", type=float, default=0.45, help="minimum match ratio 0.2-0.95 (default 0.45)")
    ap.add_argument("--no-segment-check", action="store_true", help="disable the different-cut safety check")
    ap.add_argument("--lang", choices=["en", "ar"], default=os.environ.get("SUBAUTOSYNC_LANG", "en"),
                    help="message language")
    ap.add_argument("--json", action="store_true", help="print a JSON result")
    ap.add_argument("--version", action="version", version=__version__)
    a = ap.parse_args(argv)

    with open(a.subtitle, "rb") as f:
        raw = f.read()
    ref_desc = ""
    try:
        ref, ref_desc = load_reference(a.reference, a.track)
        o = synchronize(raw, a.subtitle, ref, a.min_match, not a.no_segment_check)
    except ReferenceError_ as e:
        o = Outcome("no_reference", reason=e.reason)
        ref_desc = str(e)

    out_path = None
    if o.status == "synced":
        if a.in_place:
            shutil.copyfile(a.subtitle, a.subtitle + ".bak")
            out_path = a.subtitle
        else:
            out_path = a.output or _default_out(a.subtitle)
        with open(out_path, "wb") as f:
            f.write(o.data)

    msg = describe(o, a.lang, a.min_match)
    if a.json:
        r = o.alignment
        print(json.dumps({"status": o.status, "message": msg, "reference": ref_desc, "output": out_path,
                          "scale": r.scale if r else None, "offset_ms": r.offset_ms if r else None,
                          "matched": round(r.matched, 4) if r else None,
                          "rival": round(r.rival, 4) if r else None}, ensure_ascii=False))
    else:
        print(msg)
        if ref_desc:
            print(("المرجع: " if a.lang == "ar" else "Reference: ") + ref_desc)
        if out_path:
            print(("الملف: " if a.lang == "ar" else "Saved: ") + out_path)
    return {"synced": 0, "in_sync": 0}.get(o.status, 2)


if __name__ == "__main__":
    sys.exit(main())

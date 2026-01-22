#!/usr/bin/env python
# -*- coding: utf-8 -*-

import os, re, glob, time, random, argparse, datetime
from typing import List, Tuple
from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError

# =======================
# CONFIG (defaults)
# =======================
SINGLE_VIDEO_URL = ""  # e.g. "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
CHANNEL_URL      = "https://www.youtube.com/@danmartell"

SUB_DIR            = "subs"
MAX_VIDEOS         = None      # e.g. 100 while testing
COOKIE_FILE        = r"C:\Scripts\cookies-yt.txt"   # keep as raw string on Windows

# Start at Nth video (1-indexed). Example: 496 means skip first 495.
START_AT_DEFAULT   = 1

# Sleep controls (tune to be gentler)
PER_VIDEO_SLEEP_S  = (3, 8)    # random sleep between videos (min,max)
REQ_SLEEP_S        = (2, 5)    # random sleep between HTTP requests
BATCH_SIZE         = 100       # pause after this many videos
BATCH_PAUSE_S      = 300       # pause length between batches (seconds)

# Backoff on rate-limit
BACKOFF_SCHEDULE   = [300, 600, 1200, 1800]   # 5m, 10m, 20m, 30m

os.makedirs(SUB_DIR, exist_ok=True)

# yt-dlp options
YDL_LIST_OPTS = {
    "quiet": False,
    "extract_flat": True,
    "skip_download": True,
    "cookiefile": COOKIE_FILE,
}
YDL_META_OPTS = {
    "quiet": True,
    "skip_download": True,
    "cookiefile": COOKIE_FILE,
}
YDL_DL_OPTS = {
    "quiet": False,
    "skip_download": True,
    "writesubtitles": True,
    "writeautomaticsub": True,
    "subtitleslangs": ["en", "en-US", "en-GB"],
    "subtitlesformat": "srt",
    "retries": 10,

    # sleep BETWEEN HTTP REQUESTS (random in range)
    "sleep_interval_requests": REQ_SLEEP_S[0],
    "max_sleep_interval_requests": REQ_SLEEP_S[1],

    # sleep BETWEEN VIDEOS (random in range)
    "sleep_interval": PER_VIDEO_SLEEP_S[0],
    "max_sleep_interval": PER_VIDEO_SLEEP_S[1],

    "cookiefile": COOKIE_FILE,
    "outtmpl": {"subtitle": os.path.join(SUB_DIR, "%(id)s.%(language)s.%(ext)s")},
}

# ---------------- helpers ----------------
def sanitize_filename(name: str, max_len: int = 120) -> str:
    name = re.sub(r'[<>:"/\\|?*\x00-\x1F]', "_", name)
    name = re.sub(r"\s+", " ", name).strip(" .")
    return (name or "captions")[:max_len]

def _canonicalize_channel_url(url: str) -> str:
    if re.match(r"^https?://(www\.)?youtube\.com/@[^/]+/?$", url):
        return url.rstrip("/") + "/videos"
    return url

def list_channel_video_ids(channel_videos_url: str, limit: int | None) -> List[str]:
    url = _canonicalize_channel_url(channel_videos_url)
    print(f"Listing videos from: {url}")
    ids: List[str] = []
    with YoutubeDL(YDL_LIST_OPTS) as ydl:
        info = ydl.extract_info(url, download=False)
        for e in (info.get("entries") or []):
            if e.get("_type") == "url" and e.get("ie_key") == "Youtube" and e.get("id"):
                ids.append(e["id"])
                if limit and len(ids) >= limit:
                    break
    print(f"Found {len(ids)} video(s).")
    return ids

def resolve_channel_name_from_video(video_url_or_id: str) -> str | None:
    url = video_url_or_id
    if re.fullmatch(r"[\w-]{11}", video_url_or_id):
        url = f"https://www.youtube.com/watch?v={video_url_or_id}"
    with YoutubeDL(YDL_META_OPTS) as ydl:
        info = ydl.extract_info(url, download=False)
    for key in ("uploader", "channel", "artist", "creator", "uploader_id"):
        if info.get(key):
            return str(info[key])
    return None

def download_captions(video_url: str) -> Tuple[str, List[str]]:
    with YoutubeDL(YDL_DL_OPTS) as ydl:
        info = ydl.extract_info(video_url, download=True)
        vid = info.get("id")
    srt_paths = sorted(glob.glob(os.path.join(SUB_DIR, f"{vid}.*.srt")))
    return video_url, srt_paths

def srt_to_plain_text(srt_path: str) -> str:
    out = []
    with open(srt_path, "r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line or line.isdigit() or "-->" in line:
                continue
            cleaned = re.sub(r"\s+", " ", line).strip()
            if cleaned:
                out.append(cleaned)
    return "\n".join(out)

def append_to_output(output_file: str, header: str, url: str, body: str | None):
    with open(output_file, "a", encoding="utf-8") as out:
        out.write(f"\n\n=== {header} ===\n{url}\n\n")
        out.write(body if body else "[No transcript captured]\n")

def load_progress(progress_file: str) -> set[str]:
    if not os.path.exists(progress_file):
        return set()
    with open(progress_file, "r", encoding="utf-8") as f:
        return {ln.strip() for ln in f if ln.strip()}

def save_progress(progress_file: str, video_id: str):
    with open(progress_file, "a", encoding="utf-8") as f:
        f.write(video_id + "\n")

def is_rate_limit_error(err: Exception) -> bool:
    msg = str(err).lower()
    needles = [
        "rate-limited",
        "too many requests",
        "http error 429",
        "try again later",
        "isn't available, try again later",
    ]
    return any(n in msg for n in needles)

def backup(path: str):
    if os.path.exists(path):
        ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
        os.replace(path, f"{path}.bak-{ts}")

# ---------------- main ----------------
def parse_args():
    p = argparse.ArgumentParser(description="YouTube channel caption scraper with safe resume and start-index.")
    p.add_argument("--start", type=int, default=START_AT_DEFAULT,
                   help="Start at Nth video (1-indexed) when processing a channel (default: %(default)s).")
    p.add_argument("--max", type=int, default=None,
                   help="Process at most N videos (overrides MAX_VIDEOS if given).")
    p.add_argument("--single", type=str, default=SINGLE_VIDEO_URL,
                   help="Single video URL to process instead of a channel.")
    p.add_argument("--channel", type=str, default=CHANNEL_URL,
                   help="Channel URL (handle or /videos) to process.")
    p.add_argument("--fresh", action="store_true",
                   help="Start over: backup and recreate output/progress files.")
    return p.parse_args()

def main():
    args = parse_args()

    if args.single and args.channel and args.single.strip() and args.channel.strip():
        print("Please set ONLY one of --single or --channel.")
        return

    # Decide targets + channel name
    if args.single and args.single.strip():
        print("Mode: single video")
        targets = [args.single.strip()]
        ch_name = resolve_channel_name_from_video(args.single.strip()) or "captions"
    else:
        print("Mode: channel")
        limit = args.max if args.max is not None else MAX_VIDEOS
        ids = list_channel_video_ids(args.channel.strip(), limit)
        if not ids:
            print("No videos found.")
            return

        # Apply start index (1-indexed)
        start_at = max(1, int(args.start or 1))
        if start_at > len(ids):
            print(f"Start index {start_at} is beyond list size {len(ids)}. Nothing to do.")
            return
        ids = ids[start_at - 1:]
        print(f"Starting at video #{start_at}. Processing {len(ids)} remaining.")

        targets = [f"https://www.youtube.com/watch?v={vid}" for vid in ids]
        ch_name = resolve_channel_name_from_video(ids[0]) or "captions"

    base_name    = sanitize_filename(ch_name)
    output_file  = f"{base_name}.txt"
    progress_file = f"{base_name}.progress.txt"   # <-- per-channel progress!

    print(f"Writing to: {output_file}")
    print(f"Progress file: {progress_file}")

    # Fresh mode: backup existing files, then start new ones
    if args.fresh:
        backup(output_file)
        backup(progress_file)
        # no auto deletion—files are moved aside with .bak-<timestamp>

    # Resume support (never auto-delete)
    done = load_progress(progress_file)
    remaining = []
    for url in targets:
        vid = url.rsplit("v=", 1)[-1]
        if vid not in done:
            remaining.append(url)

    print(f"Already done (from progress): {len(done)}; remaining: {len(remaining)}")

    backoff_try = 0
    processed_since_pause = 0

    for i, url in enumerate(remaining, start=1):
        vid = url.rsplit("v=", 1)[-1]
        print(f"\n[{i}/{len(remaining)}] Fetching captions for: {url}")

        try:
            _, srt_files = download_captions(url)
            if not srt_files:
                print("  No .srt captions saved.")
                append_to_output(output_file, f"Video {vid}", url, None)
            else:
                # prefer English if available
                choice = next((p for p in srt_files if re.search(r"\.en(\.|$)", p)), srt_files[0])
                text = srt_to_plain_text(choice)
                print(f"  ✓ Captions parsed from {os.path.basename(choice)} ({len(text)} chars)")
                append_to_output(output_file, f"Video {vid}", url, text)

            save_progress(progress_file, vid)
            backoff_try = 0  # reset backoff on success
            processed_since_pause += 1

        except DownloadError as e:
            print(f"  ✗ Error: {e}")
            if is_rate_limit_error(e):
                wait = BACKOFF_SCHEDULE[min(backoff_try, len(BACKOFF_SCHEDULE)-1)]
                print(f"  ⏳ Hit rate-limit. Backing off for {wait} seconds …")
                time.sleep(wait)
                backoff_try += 1
                # retry the same URL after backoff
                continue
            else:
                append_to_output(output_file, f"Video {vid}", url, None)
                save_progress(progress_file, vid)
        except Exception as e:
            print(f"  ✗ Error: {e}")
            append_to_output(output_file, f"Video {vid}", url, None)
            save_progress(progress_file, vid)

        # batch pause to be gentle
        if BATCH_SIZE and processed_since_pause >= BATCH_SIZE:
            print(f"\n⏸  Batch pause {BATCH_PAUSE_S}s to avoid limits …")
            time.sleep(BATCH_PAUSE_S)
            processed_since_pause = 0

        # extra per-video sleep (randomized)
        sleep_s = random.uniform(*PER_VIDEO_SLEEP_S)
        time.sleep(sleep_s)

    print(f"\nDone – captions saved to {output_file}")

if __name__ == "__main__":
    main()

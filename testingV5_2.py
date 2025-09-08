#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
YouTube caption collector — v5.2 (interactive)
• Prompts at runtime:
  1) Is this a channel? [Y/n]
  2) URL (channel handle/URL or single video URL)
  3) Start at which video #? [1]
• Per-channel folder + safe resume (never auto-deletes)
• Per-video .txt and combined channel .txt ("paper style" – no timestamps)
• Gentle rate-limit handling + tunable sleeps
• Uses cookies file if present (optional)
"""

import os, re, glob, json, time, random, argparse, datetime, math
from typing import List, Tuple, Optional
from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError

# =======================
# Defaults (edit if you like)
# =======================
BASE_DIR          = "captions"
SUB_DIR_NAME      = "subs"
COOKIE_FILE       = r"C:\Scripts\cookies-yt.txt"  # set to your exported cookies file; or leave as is
USE_COOKIES_FILE  = True                          # auto-disabled if file missing
BROWSER_COOKIES   = None                          # e.g. "chrome" to pull directly from browser; None = off

# Sleeps (be gentle with YouTube)
PER_VIDEO_SLEEP_S = (3, 8)         # random sleep between videos
REQ_SLEEP_S       = (2, 5)         # yt-dlp per-request sleep
BATCH_SIZE        = 100            # pause every N processed videos (0 = off)
BATCH_PAUSE_S     = 300            # seconds to pause between batches

# Backoff when rate-limited
BACKOFF_SCHEDULE  = [300, 600, 1200, 1800]  # 5m, 10m, 20m, 30m

# =======================
# Helpers
# =======================
def ensure_dir(path: str):
    os.makedirs(path, exist_ok=True)

def sanitize_filename(name: str, max_len: int = 120) -> str:
    name = re.sub(r'[<>:"/\\|?*\x00-\x1F]', "_", name)
    name = re.sub(r"\s+", " ", name).strip(" .")
    return (name or "captions")[:max_len]

def _canonicalize_channel_url(url: str) -> str:
    # If user gave a handle homepage, go straight to /videos to avoid Shorts/Live in the list
    if re.match(r"^https?://(www\.)?youtube\.com/@[^/]+/?$", url.strip()):
        return url.rstrip("/") + "/videos"
    return url

def list_channel_video_ids(channel_videos_url: str) -> List[str]:
    url = _canonicalize_channel_url(channel_videos_url)
    print(f"Listing videos from: {url}")
    ids: List[str] = []
    with YoutubeDL({
        "quiet": False,
        "extract_flat": True,
        "skip_download": True,
        **_cookie_opts_for_listing()
    }) as ydl:
        info = ydl.extract_info(url, download=False)
        for e in (info.get("entries") or []):
            if e.get("_type") == "url" and e.get("ie_key") == "Youtube" and e.get("id"):
                ids.append(e["id"])
    print(f"Found {len(ids)} video(s).")
    return ids

def resolve_channel_name_from_video(video_url_or_id: str) -> Optional[str]:
    url = video_url_or_id
    if re.fullmatch(r"[\w-]{11}", video_url_or_id):
        url = f"https://www.youtube.com/watch?v={video_url_or_id}"
    with YoutubeDL({
        "quiet": True,
        "skip_download": True,
        **_cookie_opts_for_listing()
    }) as ydl:
        info = ydl.extract_info(url, download=False)
    for key in ("uploader", "channel", "artist", "creator", "uploader_id"):
        if info.get(key):
            return str(info[key])
    return None

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

def append_to_output(output_file: str, header: str, url: str, body: Optional[str]):
    with open(output_file, "a", encoding="utf-8") as out:
        out.write(f"\n\n=== {header} ===\n{url}\n\n")
        out.write(body if body else "[No transcript captured]\n")

def load_progress(progress_file: str) -> set:
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

def zero_pad(n: int) -> int:
    return max(2, int(math.log10(max(1, n))) + 1)

# =======================
# Cookies handling
# =======================
def _cookie_opts_for_listing():
    opts = {}
    if USE_COOKIES_FILE and os.path.exists(COOKIE_FILE):
        opts["cookiefile"] = COOKIE_FILE
    elif BROWSER_COOKIES:
        opts["cookiesfrombrowser"] = (BROWSER_COOKIES, True, None, None)
    return opts

def _cookie_opts_for_download():
    opts = {}
    if USE_COOKIES_FILE and os.path.exists(COOKIE_FILE):
        opts["cookiefile"] = COOKIE_FILE
    elif BROWSER_COOKIES:
        opts["cookiesfrombrowser"] = (BROWSER_COOKIES, True, None, None)
    return opts

# =======================
# Downloads
# =======================
def build_dl_opts(channel_sub_dir: str, sleep_video: Tuple[float, float], sleep_req: Tuple[float, float]):
    return {
        "quiet": False,
        "skip_download": True,
        "writesubtitles": True,
        "writeautomaticsub": True,
        "subtitleslangs": ["en", "en-US", "en-GB"],
        "subtitlesformat": "srt",
        "retries": 10,
        # request sleeps
        "sleep_interval_requests": sleep_req[0],
        "max_sleep_interval_requests": sleep_req[1],
        # file template for saved subtitles
        "outtmpl": {"subtitle": os.path.join(channel_sub_dir, "%(id)s.%(language)s.%(ext)s")},
        **_cookie_opts_for_download()
    }

def download_captions(video_url: str, dl_opts: dict) -> Tuple[str, List[str], dict]:
    with YoutubeDL(dl_opts) as ydl:
        info = ydl.extract_info(video_url, download=True)
        vid  = info.get("id")
    srt_dir = dl_opts["outtmpl"]["subtitle"].rsplit("%(id)s", 1)[0]
    srt_paths = sorted(glob.glob(os.path.join(srt_dir, f"{vid}.*.srt")))
    return vid, srt_paths, info

# =======================
# Interactive prompts
# =======================
def ask_yes_no(prompt: str, default_yes: bool = True) -> bool:
    suffix = " [Y/n] " if default_yes else " [y/N] "
    ans = input(prompt + suffix).strip().lower()
    if ans == "" or ans == "y" or ans == "yes":
        return True if default_yes or ans != "" else False
    if ans == "n" or ans == "no":
        return False
    # anything else → default
    return default_yes

def ask_text(prompt: str, default: Optional[str] = None) -> str:
    if default:
        val = input(f"{prompt} [{default}]: ").strip()
        return val if val else default
    return input(prompt + ": ").strip()

def ask_int(prompt: str, default: int = 1, min_val: int = 1) -> int:
    raw = input(f"{prompt} [{default}]: ").strip()
    if raw == "":
        return default
    try:
        v = int(raw)
        return max(min_val, v)
    except ValueError:
        print("  Not a number; using default.")
        return default

# =======================
# Main
# =======================
def main():
    # Optional: allow --browser-cookies and --no-cookies as flags if you want
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--no-cookies", action="store_true")
    parser.add_argument("--browser-cookies", type=str, default=None)
    args, _ = parser.parse_known_args()

    global USE_COOKIES_FILE, BROWSER_COOKIES

    if args.no_cookies:
        USE_COOKIES_FILE = False
        BROWSER_COOKIES  = None
        print("Cookies: disabled (--no-cookies)")
    elif args.browser_cookies:
        BROWSER_COOKIES  = args.browser_cookies
        USE_COOKIES_FILE = False
        print(f"Cookies: using browser cookies -> {BROWSER_COOKIES}")
    else:
        if os.path.exists(COOKIE_FILE):
            print(f"Cookies: using file -> {COOKIE_FILE}")
        else:
            USE_COOKIES_FILE = False
            print("Cookies: none found; proceeding without cookies")

    # ── Interactive section ────────────────────────────────────────────
    is_channel = ask_yes_no("Is this a channel?", default_yes=True)
    url = ask_text("Paste the URL", default="")
    if not url:
        print("No URL provided. Exiting.")
        return

    if is_channel:
        start_at = ask_int("Start at which video #?", default=1, min_val=1)
        # list IDs
        all_ids = list_channel_video_ids(url)
        if not all_ids:
            print("No videos found.")
            return
        end_at = len(all_ids)  # simplest flow; process to the end
        # slice
        slice_ids = all_ids[start_at - 1 : end_at]
        print(f"Processing slice: #{start_at}..#{end_at} (count={len(slice_ids)})")
        # prepare targets
        targets = [f"https://www.youtube.com/watch?v={vid}" for vid in slice_ids]
        # channel name from first item
        ch_name = resolve_channel_name_from_video(slice_ids[0]) or "captions"
        # for numbering files, use absolute index so filenames match the original list position
        absolute_index_start = start_at
    else:
        # single video
        targets = [url]
        ch_name = resolve_channel_name_from_video(url) or "captions"
        absolute_index_start = 1

    # ── Paths ──────────────────────────────────────────────────────────
    channel_safe = sanitize_filename(ch_name)
    channel_dir  = os.path.join(BASE_DIR, channel_safe)
    subs_dir     = os.path.join(channel_dir, SUB_DIR_NAME)
    ensure_dir(channel_dir)
    ensure_dir(subs_dir)

    output_file   = os.path.join(channel_dir, f"{channel_safe}.txt")
    progress_file = os.path.join(channel_dir, f"{channel_safe}.progress.txt")

    print(f"Writing combined to: {output_file}")
    print(f"Progress file      : {progress_file}")
    print(f"Subs directory     : {subs_dir}")

    # Resume using progress file
    done = load_progress(progress_file)
    remaining = []
    for url in targets:
        vid = url.rsplit("v=", 1)[-1]
        if vid not in done:
            remaining.append(url)

    print(f"Already done (from progress): {len(done)}; remaining: {len(remaining)}")
    if not remaining:
        print("Nothing to do. Bye!")
        return

    # yt-dlp options
    dl_opts = build_dl_opts(subs_dir, PER_VIDEO_SLEEP_S, REQ_SLEEP_S)

    processed_since_pause = 0
    backoff_try = 0
    total_pad = max(2, len(str(len(targets) + absolute_index_start - 1)))

    # Loop
    for rel_idx, url in enumerate(remaining, start=0):
        # per-video numbering uses absolute index (start_at + offset)
        abs_idx = absolute_index_start + rel_idx
        vid = url.rsplit("v=", 1)[-1]
        per_video_txt = os.path.join(channel_dir, f"{str(abs_idx).zfill(total_pad)}_{vid}.txt")

        print(f"\n[{rel_idx+1}/{len(remaining)}] Fetching captions for: {url}")
        try:
            vid_id, srt_files, info = download_captions(url, dl_opts)

            if not srt_files:
                print("  No .srt captions saved.")
                append_to_output(output_file, f"Video {vid_id}", url, None)
                with open(per_video_txt, "w", encoding="utf-8") as pv:
                    pv.write("[No transcript captured]\n")
            else:
                # pick English if present
                choice = next((p for p in srt_files if re.search(r"\.en(\.|$)", p)), srt_files[0])
                text = srt_to_plain_text(choice)
                print(f"  ✓ Captions parsed from {os.path.basename(choice)} ({len(text)} chars)")

                # per-video
                with open(per_video_txt, "w", encoding="utf-8") as pv:
                    pv.write(text if text else "[No transcript captured]\n")

                # combined
                title = info.get("title") or f"Video {vid_id}"
                append_to_output(output_file, title, url, text if text else None)

            save_progress(progress_file, vid_id)
            backoff_try = 0
            processed_since_pause += 1

        except DownloadError as e:
            print(f"  ✗ Error: {e}")
            if is_rate_limit_error(e):
                wait = BACKOFF_SCHEDULE[min(backoff_try, len(BACKOFF_SCHEDULE)-1)]
                print(f"  ⏳ Rate-limit hit. Backing off for {wait} seconds …")
                time.sleep(wait)
                backoff_try += 1
                # retry same URL
                continue
            else:
                append_to_output(output_file, f"Video {vid}", url, None)
                save_progress(progress_file, vid)
        except Exception as e:
            print(f"  ✗ Error: {e}")
            append_to_output(output_file, f"Video {vid}", url, None)
            save_progress(progress_file, vid)

        # batch pause
        if BATCH_SIZE and processed_since_pause >= BATCH_SIZE:
            print(f"\n⏸  Batch pause {BATCH_PAUSE_S}s to avoid limits …")
            time.sleep(BATCH_PAUSE_S)
            processed_since_pause = 0

        # polite sleep between videos
        time.sleep(random.uniform(*PER_VIDEO_SLEEP_S))

    print(f"\nDone – captions saved to {output_file}")

if __name__ == "__main__":
    main()

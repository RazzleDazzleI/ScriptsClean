import os
#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Caption collector (yt-dlp) — full channel OR hand-picked videos
----------------------------------------------------------------
• Pass a channel URL / raw UC-ID → scrapes the whole channel.
• Pass one or many video URLs / IDs → scrapes only those videos.
• If you give no CLI args and VIDEO_IDS is empty, it uses the
  CHANNEL_ID defined in CONFIG.

Output file is auto-named:
  • channel crawl   → "<Channel-Title>.txt"
  • video list      → "<Uploader-Name>.txt"
"""

import json, re, sys, time, requests
from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError, ExtractorError
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from tqdm import tqdm

# ── CONFIG ────────────────────────────────────────────────────────────
API_KEY = os.getenv("YOUTUBE_API_KEY")   # ← your Data-API key
CHANNEL_ID  = 'UCGq-a57w-aPwyi3pW7XLiH'                  # default channel
VIDEO_IDS   = []            # leave empty for channel mode
PER_REQUEST_DELAY = 1       # seconds between videos
MAX_VIDEOS  = None          # None = all uploads, or int limit
# ──────────────────────────────────────────────────────────────────────

SAFE = lambda s: re.sub(r'[\\/:*?"<>|]+', '', s)[:120]     # valid filename

# ── ID helpers ────────────────────────────────────────────────────────
def vid_id(arg: str) -> str | None:
    m = re.search(r'(?:v=|be/)([A-Za-z0-9_-]{11})', arg)
    return m.group(1) if m else (
        arg if re.fullmatch(r'[A-Za-z0-9_-]{11}', arg) else None)

def ch_id(arg: str) -> str | None:
    if arg.startswith('UC') and len(arg) == 24:
        return arg
    m = re.search(r'channel/(UC[A-Za-z0-9_-]{22})', arg)
    return m.group(1) if m else None

# ── Data-API helpers ─────────────────────────────────────────────────
def channel_title(cid: str) -> str:
    yt = build('youtube', 'v3', developerKey=API_KEY)
    info = yt.channels().list(id=cid, part='snippet').execute()
    return info['items'][0]['snippet']['title'] if info['items'] else cid

def all_upload_ids(cid: str) -> list[str]:
    pl_id = 'UU' + cid[2:]                  # uploads playlist
    yt = build('youtube', 'v3', developerKey=API_KEY)
    ids, token = [], None
    while True:
        resp = (yt.playlistItems()
                  .list(part='contentDetails', playlistId=pl_id,
                        maxResults=50, pageToken=token)
                  .execute())
        ids.extend(i['contentDetails']['videoId'] for i in resp['items'])
        token = resp.get('nextPageToken')
        if not token or (MAX_VIDEOS and len(ids) >= MAX_VIDEOS):
            break
    return ids[:MAX_VIDEOS] if MAX_VIDEOS else ids

# ── yt-dlp caption helpers ───────────────────────────────────────────
YDL_OPTS = {
    'skip_download'    : True,
    'writesubtitles'   : True,
    'writeautomaticsub': True,
    'subtitleslangs'   : ['en', 'en-US', 'en-GB'],
    'quiet'            : True,
    'no_warnings'      : True,
}

def fetch_json(url: str, tl=False):
    if tl and 'lang=' not in url: url += '&tlang=en'
    return json.loads(requests.get(url, timeout=15).text)

def best_caption_lines(info: dict):
    def lines_from(url, tl=False):
        try:
            data = fetch_json(url, tl)
            return ["".join(seg['utf8'] for seg in e.get('segs', []))
                    for e in data.get('events', []) if e.get('segs')]
        except (requests.RequestException, json.JSONDecodeError):
            return None

    aut = info.get('automatic_captions') or {}
    sub = info.get('subtitles')          or {}

    for k in ('en','en-US','en-GB'):
        if k in aut: return lines_from(aut[k][0]['url'])
    if aut: return lines_from(next(iter(aut.values()))[0]['url'], tl=True)

    for k in ('en','en-US','en-GB'):
        if k in sub: return lines_from(sub[k][0]['url'])
    if sub: return lines_from(next(iter(sub.values()))[0]['url'], tl=True)
    return None

def caption_info(vid: str):
    try:
        with YoutubeDL(YDL_OPTS) as ydl:
            info = ydl.extract_info(f'https://youtu.be/{vid}', download=False)
    except (DownloadError, ExtractorError):
        return None, None
    return info, best_caption_lines(info)

# ── Decide mode & filename ────────────────────────────────────────────
args = sys.argv[1:]
video_ids = []
channel_mode = False

if len(args) == 1 and ch_id(args[0]):                 # channel via CLI
    CHANNEL_ID = ch_id(args[0])
    channel_mode = True
elif args:                                            # explicit videos
    video_ids = [vid_id(a) for a in args if vid_id(a)]
    if not video_ids:
        sys.exit("No valid video IDs supplied.")
elif VIDEO_IDS:                                       # hard-coded list
    video_ids = VIDEO_IDS
else:                                                 # default channel
    channel_mode = True

if channel_mode:
    try:
        video_ids = all_upload_ids(CHANNEL_ID)
    except HttpError as e:
        sys.exit(f"Data API error: {e.error_details}")

# filename
if channel_mode:
    outfile = SAFE(channel_title(CHANNEL_ID)) + '.txt'
else:
    with YoutubeDL({'quiet': True}) as ydl:
        first_info = ydl.extract_info(f'https://youtu.be/{video_ids[0]}',
                                      download=False)
    outfile = SAFE(first_info['uploader']) + '.txt'

print(f"Processing {len(video_ids)} video(s) → {outfile}")

# ── main loop ─────────────────────────────────────────────────────────
with open(outfile, 'w', encoding='utf-8') as out:
    for vid in tqdm(video_ids, unit='video'):
        info, lines = caption_info(vid)
        if info is None:
            out.write(f"\n\n=== {vid} ===\n[Video unavailable]\n")
            continue

        out.write(f"\n\n=== {info['title']} ===\n{info['webpage_url']}\n\n")
        out.write('\n'.join(lines) + '\n' if lines else '[No captions found]\n')
        time.sleep(PER_REQUEST_DELAY)

print("Done – captions saved to", outfile)


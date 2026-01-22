import os
#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
Caption collector (yt-dlp) — full channel OR hand-picked videos.

Usage
-----
# 1) Crawl a channel
python caption_collect.py https://www.youtube.com/channel/UCsT0YIqwnpJCM-mx7-gSA4Q

# 2) One or many videos
python caption_collect.py dQw4w9WgXcQ https://youtu.be/VxMiE_stMis

# 3) Hard-code VIDEO_IDS below (overrides channel)
VIDEO_IDS = ["dQw4w9WgXcQ"]
python caption_collect.py
"""

import json, re, sys, time, requests
from yt_dlp import YoutubeDL
from yt_dlp.utils import DownloadError, ExtractorError
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from tqdm import tqdm

# ── CONFIG ────────────────────────────────────────────────────────────
API_KEY = os.getenv("YOUTUBE_API_KEY")
CHANNEL_ID  = 'UCGq-a57w-aPwyi3pW7XLiHw'   # ‹ default channel if you pass none ›

VIDEO_IDS   = []          # leave empty for channel mode
PER_REQUEST_DELAY = 1
MAX_VIDEOS  = None        # None = all uploads, or int limit
# ──────────────────────────────────────────────────────────────────────

SAFE = lambda s: re.sub(r'[\\/:*?"<>|]+', '', s)[:120]

# ── helpers to parse IDs from CLI -------------------------------------
def vid_id(arg: str) -> str | None:
    m = re.search(r'(?:v=|be/)([A-Za-z0-9_-]{11})', arg)
    return m.group(1) if m else (arg if re.fullmatch(r'[A-Za-z0-9_-]{11}', arg) else None)

def channel_id(arg: str) -> str | None:
    if arg.startswith('UC') and len(arg) == 24:
        return arg
    m = re.search(r'channel/(UC[A-Za-z0-9_-]{22})', arg)
    return m.group(1) if m else None

# ── Data-API helpers ---------------------------------------------------
def all_upload_ids(cid: str) -> list[str]:
    pl = 'UU' + cid[2:]               # channel’s uploads playlist
    yt = build('youtube', 'v3', developerKey=API_KEY)
    ids, token = [], None
    while True:
        resp = (yt.playlistItems()
                  .list(part='contentDetails', playlistId=pl,
                        maxResults=50, pageToken=token)
                  .execute())
        ids.extend(i['contentDetails']['videoId'] for i in resp['items'])
        token = resp.get('nextPageToken')
        if not token or (MAX_VIDEOS and len(ids) >= MAX_VIDEOS):
            break
    return ids[:MAX_VIDEOS] if MAX_VIDEOS else ids

def channel_title(cid: str) -> str:
    yt = build('youtube', 'v3', developerKey=API_KEY)
    info = yt.channels().list(id=cid, part='snippet').execute()
    return info['items'][0]['snippet']['title'] if info['items'] else cid

# ── yt-dlp caption utilities ------------------------------------------
YDL_OPTS = {
    'skip_download': True,
    'writesubtitles': True,
    'writeautomaticsub': True,
    'subtitleslangs': ['en', 'en-US', 'en-GB'],
    'quiet': True, 'no_warnings': True
}

def best_caption_lines(info):
    def fetch(url, trans=False):
        if trans and 'lang=' not in url: url += '&tlang=en'
        try:
            data = json.loads(requests.get(url, timeout=15).text)
            return ["".join(seg['utf8'] for seg in e.get('segs', []))
                    for e in data.get('events', []) if e.get('segs')]
        except (requests.RequestException, json.JSONDecodeError):
            return None

    aut = info.get('automatic_captions') or {}
    sub = info.get('subtitles')          or {}

    for k in ('en','en-US','en-GB'):
        if k in aut: return fetch(aut[k][0]['url'])
    if aut: return fetch(next(iter(aut.values()))[0]['url'], trans=True)
    for k in ('en','en-US','en-GB'):
        if k in sub: return fetch(sub[k][0]['url'])
    if sub: return fetch(next(iter(sub.values()))[0]['url'], trans=True)
    return None

def caption_lines(vid: str):
    try:
        with YoutubeDL(YDL_OPTS) as ydl:
            info = ydl.extract_info(f'https://youtu.be/{vid}', download=False)
    except (DownloadError, ExtractorError):
        return None, None
    lines = best_caption_lines(info)
    return info, lines

# ── figure out what to download & pick filename ------------------------
cli_ids = [vid_id(a) for a in sys.argv[1:] if vid_id(a)]

if cli_ids:                                   # video list from CLI
    video_ids = cli_ids
elif VIDEO_IDS:                               # hard-coded list
    video_ids = VIDEO_IDS
else:                                         # channel crawl
    try:
        video_ids = all_upload_ids(CHANNEL_ID)
    except HttpError as e:
        sys.exit(f"Data API error: {e.error_details}")

print(f"Processing {len(video_ids)} video(s)…")

# pick output name automatically
if len(video_ids) == 0:
    sys.exit("Nothing to process.")

if not cli_ids and not VIDEO_IDS:             # channel mode
    outfile = SAFE(channel_title(CHANNEL_ID)) + '.txt'
else:                                         # video list mode
    with YoutubeDL({'quiet': True}) as ydl:
        first = ydl.extract_info(f'https://youtu.be/{video_ids[0]}',
                                 download=False)
    outfile = SAFE(first['uploader']) + '.txt'

# ── main loop ----------------------------------------------------------
with open(outfile, 'w', encoding='utf-8') as out:
    for vid in tqdm(video_ids, unit='video'):
        info, lines = caption_lines(vid)
        if info is None:
            out.write(f"\n\n=== {vid} ===\n[Video unavailable]\n")
            continue

        out.write(f"\n\n=== {info['title']} ===\n{info['webpage_url']}\n\n")
        if not lines:
            out.write('[No captions found]\n')
        else:
            out.write('\n'.join(l.strip() for l in lines) + '\n')

        time.sleep(PER_REQUEST_DELAY)

print('Done – captions saved to', outfile)


#!/usr/bin/env python
# -*- coding: utf-8 -*-

import time, xml.etree.ElementTree as ET
from youtube_transcript_api import (YouTubeTranscriptApi,
    TranscriptsDisabled, NoTranscriptFound, CouldNotRetrieveTranscript)
from tqdm import tqdm

OUT = "test_transcripts.txt"
IDS = {
    "dQw4w9WgXcQ": "Rick Astley – Never Gonna Give You Up",
    "mmO0ImI5XlI": "Fastest Workers – Daily Dose of Internet",
    "8G1dSe4NZnk": "Where No Human Has Been – RealLifeLore",
    "mrYYqpXtds0": "Earth Stops Spinning – Kurzgesagt",
    "VxMiE_stMis": "Apple Vision Pro Impressions – MKBHD",
}
MAX_RETRIES = 5

def hms(s): m,s=divmod(int(s),60); h,m=divmod(m,60); return f"{h:02}:{m:02}:{s:02}"

def fetch(vid):
    backoff=1
    for _ in range(MAX_RETRIES):
        try:
            tl = YouTubeTranscriptApi.list_transcripts(vid)
            for t in tl:
                if t.language_code == "en":
                    return t.fetch() if t.is_generated else t.fetch()
            return tl.find_transcript([tr.language_code for tr in tl]).translate('en').fetch()
        except ET.ParseError:
            time.sleep(backoff); backoff*=2
        except (TranscriptsDisabled, NoTranscriptFound, CouldNotRetrieveTranscript):
            return None
    return None

with open(OUT,"w",encoding="utf-8") as f:
    for vid,title in tqdm(IDS.items(),unit="video"):
        f.write(f"\n\n=== {title} ===\nhttps://www.youtube.com/watch?v={vid}\n\n")
        tx=fetch(vid)
        if tx:
            for row in tx:
                f.write(f"[{hms(row['start'])}] {row['text']}\n")
        else:
            f.write("[No transcript captured]\n")
        time.sleep(1)

print("Done – see", OUT)

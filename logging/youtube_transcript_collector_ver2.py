import os
import time
import sys
import xml.etree.ElementTree as ET
from googleapiclient.discovery import build
from googleapiclient.errors import HttpError
from youtube_transcript_api import (
    YouTubeTranscriptApi,
    TranscriptsDisabled,
    NoTranscriptFound,
    CouldNotRetrieveTranscript,
)
from tqdm import tqdm

# === CONFIG ===
API_KEY = os.getenv("YOUTUBE_API_KEY")     # ← your key
CHANNEL_ID  = 'UCGq-a57w-aPwyi3pW7XLiH'                     # ← target channel
OUTPUT_FILE = 'channel_transcripts.txt'
SLEEP_SECS  = 1                                              # polite delay

# -------------------------------------------
youtube = build('youtube', 'v3', developerKey=API_KEY)

# -------------------------------------------
def get_all_video_ids(channel_id: str) -> list[str]:
    ids, token = [], None
    while True:
        try:
            resp = (
                youtube.search()
                .list(
                    part='id',
                    channelId=channel_id,
                    maxResults=50,
                    type='video',
                    order='date',
                    pageToken=token,
                )
                .execute()
            )
        except HttpError as e:
            print(f"[YouTube API] HTTP {e.resp.status}: {e.error_details}")
            sys.exit(1)

        for item in resp.get("items", []):
            if "videoId" in item["id"]:
                ids.append(item["id"]["videoId"])

        token = resp.get("nextPageToken")
        if not token:
            break
    return ids

# -------------------------------------------
def get_video_titles(video_ids: list[str]) -> dict[str, str]:
    titles = {}
    for i in range(0, len(video_ids), 50):
        batch = video_ids[i : i + 50]
        try:
            resp = youtube.videos().list(part="snippet", id=",".join(batch)).execute()
            for v in resp.get("items", []):
                titles[v["id"]] = v["snippet"]["title"]
        except HttpError:
            continue
    return titles

# -------------------------------------------
def fmt(seconds: float) -> str:
    m, s = divmod(int(seconds), 60)
    h, m = divmod(m, 60)
    return f"{h:02}:{m:02}:{s:02}"

# -------------------------------------------
def fetch_auto_transcript(vid: str):
    """Return auto-generated transcript list or None."""
    try:
        tlist = YouTubeTranscriptApi.list_transcripts(vid)

        # Prefer auto-generated English
        for t in tlist:
            if t.is_generated and t.language_code == "en":
                return t.fetch()

        # Otherwise any auto-generated language
        for t in tlist:
            if t.is_generated:
                return t.fetch()

        raise NoTranscriptFound

    except (
        TranscriptsDisabled,
        NoTranscriptFound,
        CouldNotRetrieveTranscript,
        ET.ParseError,          # ← handles empty/invalid XML
    ):
        return None

# -------------------------------------------
def main():
    print("Gathering video IDs…")
    vids   = get_all_video_ids(CHANNEL_ID)
    titles = get_video_titles(vids)
    print(f"Found {len(vids)} videos. Writing to '{OUTPUT_FILE}'")

    with open(OUTPUT_FILE, "a", encoding="utf-8") as out:
        for vid in tqdm(vids, unit="video"):
            title = titles.get(vid, vid)
            url   = f"https://www.youtube.com/watch?v={vid}"
            out.write(f"\n\n=== {title} ===\n{url}\n\n")

            transcript = fetch_auto_transcript(vid)
            if transcript:
                for row in transcript:
                    out.write(f"[{fmt(row['start'])}] {row['text']}\n")
            else:
                out.write("[No auto-generated transcript available]\n")

            time.sleep(SLEEP_SECS)

    print("Done ✅")

# -------------------------------------------
if __name__ == "__main__":
    main()


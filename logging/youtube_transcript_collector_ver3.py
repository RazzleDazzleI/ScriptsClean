import os
import time, random, sys
from pathlib import Path
from googleapiclient.discovery import build
from youtube_transcript_api import (
    YouTubeTranscriptApi,
    TranscriptsDisabled,
    NoTranscriptFound,
)

# === CONFIG ===
API_KEY = os.getenv("YOUTUBE_API_KEY")
CHANNEL_ID = "UCGq-a57w-aPwyi3pW7XLiH"
DELAY_SECS = 1.0
OUT_DIR    = Path("transcripts")
OUT_DIR.mkdir(exist_ok=True)

youtube = build("youtube", "v3", developerKey=API_KEY)

# ---------- helpers ----------
def clean(text: str) -> str:
    return "".join(c if c.isalnum() or c in (" ", "_", "-") else "_" for c in text)

def get_channel_title(cid: str) -> str:
    info = youtube.channels().list(part="snippet", id=cid).execute()["items"][0]
    return clean(info["snippet"]["title"]).replace(" ", "_")

TITLE         = get_channel_title(CHANNEL_ID)
OUTPUT_FILE   = OUT_DIR / f"channel_transcripts_{TITLE}.txt"
ERROR_LOG     = OUT_DIR / "transcript_errors.log"

def uploads_playlist_id(cid: str) -> str:
    return (
        youtube.channels()
        .list(part="contentDetails", id=cid)
        .execute()["items"][0]["contentDetails"]["relatedPlaylists"]["uploads"]
    )

def all_video_ids(cid: str) -> list[str]:
    plid, vids, token = uploads_playlist_id(cid), [], None
    while True:
        resp = youtube.playlistItems().list(
            part="contentDetails", playlistId=plid, maxResults=50, pageToken=token
        ).execute()
        vids += [it["contentDetails"]["videoId"] for it in resp["items"]]
        token = resp.get("nextPageToken")
        if not token:
            break
    return vids

def video_titles(ids: list[str]) -> dict[str, str]:
    titles = {}
    for i in range(0, len(ids), 50):
        resp = youtube.videos().list(part="snippet", id=",".join(ids[i:i+50])).execute()
        titles.update({it["id"]: it["snippet"]["title"] for it in resp["items"]})
    return titles

def hhmmss(sec: float) -> str:
    h, m = divmod(int(sec), 3600)
    m, s = divmod(m, 60)
    return f"{h:02}:{m:02}:{s:02}"

def fetch_with_retry(trans, tries=3):
    back = 2.0
    for n in range(tries):
        try:
            return trans.fetch()
        except Exception:
            if n == tries - 1:
                raise
            time.sleep(back)
            back *= 1.6

def log_error(vid, title, msg):
    with ERROR_LOG.open("a", encoding="utf-8") as f:
        f.write(f"{vid} — {title} — {msg}\n")

# ---------- main ----------
def main():
    print("Fetching video IDs …")
    vids = all_video_ids(CHANNEL_ID)
    print(f"Found {len(vids):,} videos.")
    titles = video_titles(vids)

    from tqdm import tqdm
    with OUTPUT_FILE.open("w", encoding="utf-8") as out:
        for vid in tqdm(vids, desc="Transcripts", unit="video"):
            title = titles.get(vid, vid)
            out.write(f"\n\n=== {title} ===\nhttps://youtu.be/{vid}\n\n")
            try:
                tl = YouTubeTranscriptApi.list_transcripts(vid)
                tr = tl.find_transcript(["en-US", "en", "a.en-US", "a.en"])
                for item in fetch_with_retry(tr):
                    out.write(f"[{hhmmss(item['start'])}] {item['text']}\n")
            except (TranscriptsDisabled, NoTranscriptFound):
                out.write("[Transcript unavailable]\n")
                log_error(vid, title, "No transcript")
            except Exception as e:
                out.write(f"[Error: {type(e).__name__}]\n")
                log_error(vid, title, type(e).__name__)
            time.sleep(DELAY_SECS)

    print(f"Done - transcripts → {OUTPUT_FILE}\nErrors → {ERROR_LOG}")

if __name__ == "__main__":
    main()


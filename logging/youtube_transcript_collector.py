import os
import time
from googleapiclient.discovery import build
from youtube_transcript_api import YouTubeTranscriptApi, TranscriptsDisabled, NoTranscriptFound
from tqdm import tqdm

API_KEY = os.getenv("YOUTUBE_API_KEY")

CHANNEL_ID = 'UCWsXsuBcLoan5rBm4u33apA'
OUTPUT_FILE = 'channel_transcripts_Whiteout.txt'

youtube = build('youtube', 'v3', developerKey=API_KEY)

def get_all_video_ids(channel_id):
    video_ids = []
    next_page_token = None

    while True:
        request = youtube.search().list(
            part='id',
            channelId=channel_id,
            maxResults=50,
            order='date',
            type='video',
            pageToken=next_page_token
        )
        response = request.execute()

        for item in response['items']:
            video_ids.append(item['id']['videoId'])

        next_page_token = response.get('nextPageToken')
        if not next_page_token:
            break

    return video_ids

def get_video_titles(video_ids):
    titles = {}
    for i in range(0, len(video_ids), 50):
        batch = video_ids[i:i + 50]
        request = youtube.videos().list(
            part='snippet',
            id=','.join(batch)
        )
        response = request.execute()
        for item in response['items']:
            titles[item['id']] = item['snippet']['title']
    return titles

def format_timestamp(seconds):
    mins, secs = divmod(int(seconds), 60)
    hours, mins = divmod(mins, 60)
    return f"{hours:02}:{mins:02}:{secs:02}"

def save_combined_transcripts(video_ids, titles):
    with open(OUTPUT_FILE, 'w', encoding='utf-8') as output:
        for video_id in tqdm(video_ids, desc="Fetching transcripts", unit="video"):
            title = titles.get(video_id, f"video_{video_id}")
            url = f"https://www.youtube.com/watch?v={video_id}"
            output.write(f"\n\n=== {title} ===\n{url}\n\n")
            try:
                transcript = YouTubeTranscriptApi.get_transcript(video_id)
                for entry in transcript:
                    timestamp = format_timestamp(entry['start'])
                    output.write(f"[{timestamp}] {entry['text']}\n")
            except (TranscriptsDisabled, NoTranscriptFound):
                output.write("[No transcript available]\n")
            except Exception as e:
                output.write(f"[Error: {e}]\n")
            time.sleep(1)

def main():
    print("Getting video list...")
    video_ids = get_all_video_ids(CHANNEL_ID)
    titles = get_video_titles(video_ids)

    print(f"Found {len(video_ids)} videos. Saving transcripts to '{OUTPUT_FILE}'...")
    save_combined_transcripts(video_ids, titles)
    print("Done ✅")

if __name__ == '__main__':
    main()


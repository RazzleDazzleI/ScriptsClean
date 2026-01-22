import os
import json
import time
from googleapiclient.discovery import build
from youtube_transcript_api import YouTubeTranscriptApi, TranscriptsDisabled, NoTranscriptFound

API_KEY = os.getenv("YOUTUBE_API_KEY")
CHANNEL_ID = 'UCXXXXXXXXXXXXXXXX'  # Replace with your target channel ID

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

def save_transcript(video_id, title):
    try:
        transcript = YouTubeTranscriptApi.get_transcript(video_id)
        safe_title = "".join(c for c in title if c.isalnum() or c in " -_").rstrip()
        with open(f"{safe_title or video_id}.txt", "w", encoding="utf-8") as f:
            for entry in transcript:
                f.write(f"{entry['text']}\n")
        print(f"Saved transcript for {video_id}")
    except (TranscriptsDisabled, NoTranscriptFound) as e:
        print(f"No transcript available for {video_id}: {e}")
    except Exception as e:
        print(f"Error fetching transcript for {video_id}: {e}")

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

def main():
    video_ids = get_all_video_ids(CHANNEL_ID)
    titles = get_video_titles(video_ids)

    print(f"Found {len(video_ids)} videos.")
    for video_id in video_ids:
        title = titles.get(video_id, f"video_{video_id}")
        save_transcript(video_id, title)
        time.sleep(1)  # Avoid rate limiting

if __name__ == '__main__':
    main()


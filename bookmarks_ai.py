# -*- coding: utf-8 -*-
import json
import os
from openai import OpenAI

print("[START] Script started...")


try:
    with open(r"C:\Scripts\bookmarks.json", "r", encoding="utf-8") as f:
        bookmarks = json.load(f)
    print(f"[INFO] Loaded {len(bookmarks)} bookmarks.")
except Exception as e:
    print(f"[ERROR] Failed to load bookmarks.json: {e}")
    exit()

lines = [f'"{b["name"]}" - {b["url"]}' for b in bookmarks]
joined_bookmarks = "\n".join(lines[:50])


prompt = f"""
You are an expert at organizing information. I have a list of Chrome bookmarks.

Each line has a bookmark with a name and a URL. Please group them into logical folders based on category or topic.

Output JSON in this format:
{{
  "Folder Name": [{{"name": "...", "url": "..."}}],
  "Another Folder": [{{"name": "...", "url": "..."}}]
}}

Bookmarks:
{joined_bookmarks}
"""

print("[INFO] Sending request to GPT-4...")

try:
    response = client.chat.completions.create(
        model="gpt-4",
        messages=[
            {"role": "system", "content": "You are a helpful assistant that organizes bookmarks."},
            {"role": "user", "content": prompt}
        ],
        temperature=0.4,
        timeout=90
    )

    organized_json = response.choices[0].message.content.strip()
    print("[INFO] GPT-4 responded.")
except Exception as e:
    print(f"[ERROR] OpenAI call failed: {e}")
    organized_json = ""

output_file = r"C:\Scripts\organized_bookmarks.json"

if organized_json:
    try:
        with open(output_file, "w", encoding="utf-8") as f:
            f.write(organized_json)
        print(f"[SUCCESS] File saved to: {output_file}")
    except Exception as e:
        print(f"[ERROR] Failed to write file: {e}")
else:
    print("[WARNING] GPT returned no content.")

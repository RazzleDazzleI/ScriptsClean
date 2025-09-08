import os
import requests
from requests.auth import HTTPBasicAuth
from bs4 import BeautifulSoup
import os
import time
import re
import csv

# --- CONFIGURATION ---
EMAIL = "you@example.com"          # Replace with your Confluence email
API_TOKEN = os.getenv("CONFLUENCE_TOKEN")       # Replace with your Atlassian API token
BASE_URL = "https://sitesage.atlassian.net/wiki"
AUTH = HTTPBasicAuth(EMAIL, API_TOKEN)

# --- SETUP ---
os.makedirs("confluence_pages", exist_ok=True)

def sanitize_filename(title):
    return re.sub(r'[\\/:*?"<>|]', "_", title)

def fetch_all_pages(start=0, limit=50):
    pages = []
    while True:
        url = f"{BASE_URL}/rest/api/content?limit={limit}&start={start}&expand=body.storage,version,space"
        response = requests.get(url, auth=AUTH)
        data = response.json()

        pages.extend(data.get("results", []))
        if data["_links"].get("next"):
            start += limit
            time.sleep(1)
        else:
            break
    return pages

def save_page(page):
    title = sanitize_filename(page['title'])
    content_html = page['body']['storage']['value']
    space_key = page.get('space', {}).get('key', 'unknown')
    page_id = page['id']
    url = f"{BASE_URL}/spaces/{space_key}/pages/{page_id}"

    version_info = page.get("version", {})
    version = version_info.get("number", "unknown")
    updated = version_info.get("when", "unknown")
    updated_by = version_info.get("by", {}).get("displayName", "unknown")

    folder_path = os.path.join("confluence_pages", space_key)
    os.makedirs(folder_path, exist_ok=True)

    # Convert HTML to plain text
    soup = BeautifulSoup(content_html, "html.parser")
    plain_text = soup.get_text()

    # Save plain text with metadata
    txt_path = os.path.join(folder_path, f"{title}.txt")
    with open(txt_path, "w", encoding="utf-8") as f:
        f.write(f"Title: {title}\n")
        f.write(f"Space: {space_key}\n")
        f.write(f"Page ID: {page_id}\n")
        f.write(f"Version #: {version}\n")
        f.write(f"Last Updated: {updated}\n")
        f.write(f"Updated By: {updated_by}\n")
        f.write(f"Source URL: {url}\n")
        f.write("\n" + plain_text)

    return {
        "title": title,
        "page_id": page_id,
        "space": space_key,
        "version": version,
        "updated": updated,
        "updated_by": updated_by,
        "url": url
    }

def main():
    print("Fetching all Confluence pages...")
    pages = fetch_all_pages()
    print(f"Found {len(pages)} pages.")

    csv_path = "confluence_index.csv"
    with open(csv_path, "w", newline="", encoding="utf-8") as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(["Title", "Page ID", "Space", "Version", "Updated", "Updated By", "URL"])

        for page in pages:
            info = save_page(page)
            writer.writerow([
                info["title"],
                info["page_id"],
                info["space"],
                info["version"],
                info["updated"],
                info["updated_by"],
                info["url"]
            ])

    print("✅ Download complete.")
    print("📁 Pages saved to `confluence_pages/<space>/` folders.")
    print(f"📄 Index written to `{csv_path}`.")

if __name__ == "__main__":
    main()


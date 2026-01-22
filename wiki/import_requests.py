import requests
from requests.auth import HTTPBasicAuth
from bs4 import BeautifulSoup
from dotenv import load_dotenv
import os
import time
import re

# Load environment variables from .env
load_dotenv()

EMAIL = "drmitrromero@gmail.com"
API_TOKEN = os.getenv("CONFLUENCE_TOKEN")
BASE_URL = "https://sitesage.atlassian.net/wiki"
AUTH = HTTPBasicAuth(EMAIL, API_TOKEN)

OUTPUT_DIR = "confluence_pages"
os.makedirs(OUTPUT_DIR, exist_ok=True)

def fetch_all_pages(limit=50):
    print("Fetching Confluence pages...")
    start = 0
    all_pages = []

    while True:
        url = f"{BASE_URL}/rest/api/content?limit={limit}&start={start}&expand=body.storage"
        response = requests.get(url, auth=AUTH)

        if response.status_code != 200:
            print(f"Error {response.status_code}: {response.text}")
            break

        data = response.json()
        pages = data.get("results", [])
        all_pages.extend(pages)

        print(f"Fetched {len(all_pages)} pages...")

        if "_links" in data and "next" in data["_links"]:
            start += limit
            time.sleep(1)
        else:
            break

    return all_pages

def save_page(page, as_html=False):
    title = re.sub(r'[<>:"/\\|?*]', '_', page["title"]).strip()
    content_html = page["body"]["storage"]["value"]
    filename = f"{title}.html" if as_html else f"{title}.txt"
    filepath = os.path.join(OUTPUT_DIR, filename)

    if as_html:
        content = content_html
    else:
        soup = BeautifulSoup(content_html, "html.parser")
        content = soup.get_text()

    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)
    
    print(f"[Saved] {title}")

def download_attachments(page_id, page_title):
    clean_title = re.sub(r'[<>:"/\\|?*]', '_', page_title).strip()
    attachments_dir = os.path.join(OUTPUT_DIR, clean_title + "_attachments")
    os.makedirs(attachments_dir, exist_ok=True)

    url = f"{BASE_URL}/rest/api/content/{page_id}/child/attachment?limit=100"
    response = requests.get(url, auth=AUTH)

    if response.status_code != 200:
        print(f"[Warning] Failed to fetch attachments for {clean_title}")
        return

    data = response.json()
    attachments = data.get("results", [])

    for attachment in attachments:
        file_url = attachment["_links"]["download"]
        file_name = re.sub(r'[<>:"/\\|?*]', '_', attachment["title"]).strip()
        full_url = BASE_URL + file_url

        try:
            print(f"[Downloading] {file_name}")
        except UnicodeEncodeError:
            print("[Downloading] <unprintable filename>")
            with open("download_errors.log", "a", encoding="utf-8") as log:
                log.write(f"{page_title}: {file_name}\n")

        file_response = requests.get(full_url, auth=AUTH, stream=True)

        if file_response.status_code == 200:
            file_path = os.path.join(attachments_dir, file_name)
            with open(file_path, "wb") as f:
                for chunk in file_response.iter_content(chunk_size=8192):
                    f.write(chunk)
        else:
            print(f"[Error] Failed to download {file_name} ({file_response.status_code})")

def run(as_html=False):
    pages = fetch_all_pages()
    print(f"Saving {len(pages)} pages and attachments...")
    for page in pages:
        save_page(page, as_html=as_html)
        download_attachments(page["id"], page["title"])
    print(f"All content saved to '{OUTPUT_DIR}'.")

if __name__ == "__main__":
    run(as_html=False)  # Change to True if you want raw HTML instead of plain text

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Soundwise full-library backup v2 - 2025

Changes from v1:
- Credentials loaded from .env file (more secure than CLI args)
- Exponential backoff on download failures
- Resume capability (skip already-downloaded courses)
- User-agent header to avoid blocking
- Better progress reporting

Usage:
  # Set credentials in .env file, then:
  python soundwise_backup_v2.py

  # Or override via CLI:
  python soundwise_backup_v2.py --email user@example.com --password mypass

  # Resume from previous run:
  python soundwise_backup_v2.py --resume
"""

import asyncio
import csv
import datetime
import hashlib
import re
import sys
import os
import json
import argparse
import aiohttp
import aiofiles
from pathlib import Path
from dotenv import load_dotenv
from slugify import slugify
from tqdm.asyncio import tqdm
from playwright.async_api import async_playwright, TimeoutError

# Load environment variables
load_dotenv()

# ─── USER SETTINGS ───────────────────────────────────────────────────
HEADLESS = os.getenv("SOUNDWISE_HEADLESS", "false").lower() == "true"
SCROLL_PAUSE_SEC = float(os.getenv("SOUNDWISE_SCROLL_PAUSE", "0.5"))
ROOT_DIR = Path(os.getenv("SOUNDWISE_OUTPUT_DIR", "SoundwiseBackups")) / datetime.date.today().isoformat()
CONCURRENCY = int(os.getenv("SOUNDWISE_CONCURRENCY", "6"))
MAX_RETRIES = int(os.getenv("SOUNDWISE_MAX_RETRIES", "3"))
PLAY_SELECTORS = [
    'div.track-pause-play',      # wrapper around the play icon
    'i.material-icons.play',     # <i> tag itself (fallback)
]
USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
# ─────────────────────────────────────────────────────────────────────


def parse_args():
    parser = argparse.ArgumentParser(
        description="Backup all audio content from your Soundwise library.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Environment variables (set in .env file):
  SOUNDWISE_EMAIL     - Your Soundwise account email
  SOUNDWISE_PASSWORD  - Your Soundwise account password
  SOUNDWISE_HEADLESS  - Run browser in headless mode (true/false)
  SOUNDWISE_OUTPUT_DIR - Output directory for backups
  SOUNDWISE_CONCURRENCY - Number of concurrent downloads
        """
    )
    parser.add_argument(
        "--email",
        default=os.getenv("SOUNDWISE_EMAIL"),
        help="Soundwise email (or set SOUNDWISE_EMAIL in .env)"
    )
    parser.add_argument(
        "--password",
        default=os.getenv("SOUNDWISE_PASSWORD"),
        help="Soundwise password (or set SOUNDWISE_PASSWORD in .env)"
    )
    parser.add_argument(
        "--resume",
        action="store_true",
        help="Resume from previous run, skipping already-downloaded courses"
    )
    parser.add_argument(
        "--headless",
        action="store_true",
        default=HEADLESS,
        help="Run browser in headless mode"
    )
    parser.add_argument(
        "--output-dir",
        default=str(ROOT_DIR.parent),
        help="Base output directory for backups"
    )
    return parser.parse_args()


# ─── small helpers ──────────────────────────────────────────────────
def sha256sum(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


async def fetch_with_retry(session, url, dest, max_retries=MAX_RETRIES):
    """Fetch URL with exponential backoff on failures."""
    backoff = 1.0
    last_error = None

    for attempt in range(max_retries):
        try:
            async with session.get(url) as r:
                r.raise_for_status()
                async with aiofiles.open(dest, "wb") as f:
                    async for chunk in r.content.iter_chunked(1 << 20):
                        await f.write(chunk)
            return True
        except Exception as e:
            last_error = e
            if attempt < max_retries - 1:
                await asyncio.sleep(backoff)
                backoff *= 2  # Exponential backoff

    print(f"   – Failed to download after {max_retries} attempts: {last_error}")
    return False


def load_progress(progress_file: Path) -> set:
    """Load completed courses from progress file."""
    if progress_file.exists():
        try:
            with open(progress_file, "r") as f:
                data = json.load(f)
                return set(data.get("completed_courses", []))
        except Exception:
            pass
    return set()


def save_progress(progress_file: Path, completed: set):
    """Save completed courses to progress file."""
    try:
        with open(progress_file, "w") as f:
            json.dump({
                "completed_courses": list(completed),
                "last_updated": datetime.datetime.now().isoformat()
            }, f, indent=2)
    except Exception as e:
        print(f"Warning: Could not save progress: {e}")
# ─────────────────────────────────────────────────────────────────────


async def click_login(page):
    for lab in [r"log ?in", r"sign ?in", r"continue"]:
        try:
            await page.get_by_role("button", name=re.compile(lab, re.I)).click(timeout=3_000)
            return
        except TimeoutError:
            continue
    await page.locator('input[type="password"]').press("Enter")


async def login(page, email, pwd):
    await page.goto("https://app.mysoundwise.com/signin", timeout=0)
    await page.fill('input[type="email"]', email)
    await page.fill('input[type="password"]', pwd)
    await click_login(page)
    await page.wait_for_url("**/mysoundcasts**", timeout=45_000)


async def list_soundcast_cards(page):
    """Wait up to 60 s for cards, then return them."""
    await page.wait_for_selector('a[href*="/mysoundcasts/"] label',
                                 state="visible",
                                 timeout=60_000)
    cards = page.locator('a[href*="/mysoundcasts/"]')
    return cards, await cards.count()


async def trigger_all_plays(page, audio_links):
    """
    Click every play icon. After each click wait until the first media response
    (resource_type == "media") or 6 s, then pause.
    """
    for sel in PLAY_SELECTORS:
        buttons = page.locator(sel)
        if await buttons.count():
            break
    else:
        print("   – no play buttons found; skipping.")
        return

    total = await buttons.count()

    for idx in range(total):
        btn = buttons.nth(idx)
        await btn.scroll_into_view_if_needed()

        # wait for the audio request
        async with page.expect_response(
            lambda r: r.request.resource_type == "media",
            timeout=6_000
        ) as resp_info:
            await btn.click()

        # store url
        try:
            resp = await resp_info.value
            audio_links.setdefault(resp.url, None)
        except TimeoutError:
            pass  # pdf-only or slow track

        await page.wait_for_timeout(500)   # grace
        try:
            await btn.click()              # pause
        except Exception:
            pass


async def backup_one_title(page, slug, global_rows, root_dir):
    audio_links = {}

    page.on("response",
            lambda r: audio_links.setdefault(r.url, None)
            if r.request.resource_type == "media" else None)

    await trigger_all_plays(page, audio_links)

    if not audio_links:
        print("   – 0 tracks (maybe PDFs-only).")
        return

    dest = root_dir / slug
    dest.mkdir(parents=True, exist_ok=True)
    print(f"   – {len(audio_links)} tracks")

    sem, rows = asyncio.Semaphore(CONCURRENCY), []

    # Create session with custom user-agent
    headers = {"User-Agent": USER_AGENT}
    async with aiohttp.ClientSession(headers=headers) as sess:
        async def grab(u):
            async with sem:
                stem = u.split("/")[-1].split("?")[0]
                safe = slugify(stem.rsplit(".", 1)[0], max_length=60) + ".mp3"
                success = await fetch_with_retry(sess, u, dest / safe)
                if success:
                    rows.append([safe, stem, u])
        await tqdm.gather(*[grab(u) for u in audio_links])

    with open(dest / "index.csv", "w", newline="", encoding="utf-8") as f:
        csv.writer(f).writerows([["file", "orig_filename", "source_url"], *rows])

    with open(dest / "checksums.sha256", "w") as f:
        for name, *_ in rows:
            f.write(f"{sha256sum(dest / name)}  {name}\n")

    for r in rows:
        global_rows.append([slug, *r])


async def main(email, pwd, resume=False, headless=False, output_dir=None):
    # Setup output directory
    root_dir = Path(output_dir) / datetime.date.today().isoformat() if output_dir else ROOT_DIR
    root_dir.mkdir(parents=True, exist_ok=True)

    progress_file = root_dir.parent / ".soundwise_progress.json"
    completed_courses = load_progress(progress_file) if resume else set()

    if resume and completed_courses:
        print(f"Resuming: {len(completed_courses)} courses already completed")

    global_rows = []

    async with async_playwright() as p:
        browser = await p.chromium.launch(
            headless=headless,
            slow_mo=50 if not headless else 0
        )
        context = await browser.new_context(user_agent=USER_AGENT)
        page = await context.new_page()

        await login(page, email, pwd)
        cards, total = await list_soundcast_cards(page)
        print(f"Found {total} sound-casts")

        for i in range(total):
            card = cards.nth(i)
            full_text = (await card.inner_text()).strip()
            title = full_text.splitlines()[0]  # drop "Current access…"
            slug = slugify(title, max_length=80)

            # Skip if already completed (resume mode)
            if slug in completed_courses:
                print(f"\n[SKIP] {i+1}/{total}  {title} (already downloaded)")
                continue

            print(f"\n[{i+1}/{total}]  {title}")
            await card.scroll_into_view_if_needed()
            await card.click()

            # wait for a play icon instead of network-idle
            await page.wait_for_selector('div.track-pause-play', timeout=60_000)

            try:
                await backup_one_title(page, slug, global_rows, root_dir)
                # Mark as completed
                completed_courses.add(slug)
                save_progress(progress_file, completed_courses)
            except Exception as e:
                print(f"   – Error: {e}")

            await page.go_back()
            await page.wait_for_selector('a[href*="/mysoundcasts/"] label',
                                         timeout=60_000)

        await browser.close()

    if global_rows:
        with open(root_dir / "global_index.csv", "w", newline="", encoding="utf-8") as g:
            csv.writer(g).writerows(
                [["title_slug", "file", "orig_filename", "source_url"], *global_rows]
            )
    print(f"\nFinished! Backups in: {root_dir}")


if __name__ == "__main__":
    args = parse_args()

    if not args.email or not args.password:
        print("Error: Email and password required.")
        print("Set SOUNDWISE_EMAIL and SOUNDWISE_PASSWORD in .env file")
        print("Or use --email and --password arguments")
        sys.exit(1)

    asyncio.run(main(
        args.email,
        args.password,
        resume=args.resume,
        headless=args.headless,
        output_dir=args.output_dir
    ))

#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Soundwise full-library backup – 2025-07-01
"""

import asyncio, csv, datetime, hashlib, re, sys, aiohttp, aiofiles
from pathlib import Path
from slugify import slugify
from tqdm.asyncio import tqdm
from playwright.async_api import async_playwright, TimeoutError

# ─── USER SETTINGS ───────────────────────────────────────────────────
HEADLESS         = False          # False ⇒ watch the browser
SCROLL_PAUSE_SEC = 0.5
ROOT_DIR         = Path("SoundwiseBackups") / datetime.date.today().isoformat()
CONCURRENCY      = 6
PLAY_SELECTORS   = [
    'div.track-pause-play',      # wrapper around the play icon
    'i.material-icons.play',     # <i> tag itself (fallback)
]
# ─────────────────────────────────────────────────────────────────────


# ─── small helpers ──────────────────────────────────────────────────
def sha256sum(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            h.update(chunk)
    return h.hexdigest()


async def fetch(session, url, dest):
    async with session.get(url) as r:
        r.raise_for_status()
        async with aiofiles.open(dest, "wb") as f:
            async for chunk in r.content.iter_chunked(1 << 20):
                await f.write(chunk)
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


async def backup_one_title(page, slug, global_rows):
    audio_links = {}

    page.on("response",
            lambda r: audio_links.setdefault(r.url, None)
            if r.request.resource_type == "media" else None)

    await trigger_all_plays(page, audio_links)

    if not audio_links:
        print("   – 0 tracks (maybe PDFs-only).")
        return

    dest = ROOT_DIR / slug
    dest.mkdir(parents=True, exist_ok=True)
    print(f"   – {len(audio_links)} tracks")

    sem, rows = asyncio.Semaphore(CONCURRENCY), []
    async with aiohttp.ClientSession() as sess:
        async def grab(u):
            async with sem:
                stem = u.split("/")[-1].split("?")[0]
                safe = slugify(stem.rsplit(".", 1)[0], max_length=60) + ".mp3"
                await fetch(sess, u, dest / safe)
                rows.append([safe, stem, u])
        await tqdm.gather(*[grab(u) for u in audio_links])

    with open(dest / "index.csv", "w", newline="", encoding="utf-8") as f:
        csv.writer(f).writerows([["file", "orig_filename", "source_url"], *rows])

    with open(dest / "checksums.sha256", "w") as f:
        for name, *_ in rows:
            f.write(f"{sha256sum(dest / name)}  {name}\n")

    for r in rows:
        global_rows.append([slug, *r])


async def main(email, pwd):
    ROOT_DIR.mkdir(parents=True, exist_ok=True)
    global_rows = []

    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=HEADLESS,
                                          slow_mo=50 if not HEADLESS else 0)
        page = await browser.new_page()
        await login(page, email, pwd)
        cards, total = await list_soundcast_cards(page)
        print(f"📚  {total} sound-casts found")

        for i in range(total):
            card = cards.nth(i)
            full_text = (await card.inner_text()).strip()
            title = full_text.splitlines()[0]  # drop “Current access…”
            slug  = slugify(title, max_length=80)
            print(f"\n▶ {i+1}/{total}  {title}")
            await card.scroll_into_view_if_needed()
            await card.click()

            # wait for a play icon instead of network-idle
            await page.wait_for_selector('div.track-pause-play', timeout=60_000)

            try:
                await backup_one_title(page, slug, global_rows)
            except Exception as e:
                print(f"   – Error: {e}")

            await page.go_back()
            await page.wait_for_selector('a[href*="/mysoundcasts/"] label',
                                         timeout=60_000)

        await browser.close()

    if global_rows:
        with open(ROOT_DIR / "global_index.csv", "w", newline="", encoding="utf-8") as g:
            csv.writer(g).writerows(
                [["title_slug", "file", "orig_filename", "source_url"], *global_rows]
            )
    print(f"\n✅  Finished – backups in: {ROOT_DIR}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python soundwise_backup.py <email> <password>")
        sys.exit(1)
    asyncio.run(main(*sys.argv[1:]))

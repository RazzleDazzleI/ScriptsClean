# -*- coding: utf-8 -*-
"""
Bookmarks AI Organizer v2

Changes from v1:
- Configurable input/output paths via arguments or .env
- Batching support for unlimited bookmarks (processes in chunks)
- Dry-run option to preview without API calls
- Better error handling and progress reporting
- Support for different output formats

Usage:
  python bookmarks_ai_v2.py
  python bookmarks_ai_v2.py --input bookmarks.json --output organized.json
  python bookmarks_ai_v2.py --dry-run
  python bookmarks_ai_v2.py --batch-size 100
"""

import json
import os
import sys
import argparse
from pathlib import Path
from dotenv import load_dotenv
from openai import OpenAI

# Load environment variables from .env file
load_dotenv()

# Default configuration
DEFAULT_INPUT = os.getenv("BOOKMARKS_INPUT", r"C:\Scripts\bookmarks.json")
DEFAULT_OUTPUT = os.getenv("BOOKMARKS_OUTPUT", r"C:\Scripts\organized_bookmarks.json")
DEFAULT_BATCH_SIZE = int(os.getenv("BOOKMARKS_BATCH_SIZE", "50"))
DEFAULT_MODEL = os.getenv("OPENAI_MODEL", "gpt-4")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Organize Chrome bookmarks into logical folders using AI.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python bookmarks_ai_v2.py
  python bookmarks_ai_v2.py --input my_bookmarks.json --output organized.json
  python bookmarks_ai_v2.py --dry-run --batch-size 100
  python bookmarks_ai_v2.py --model gpt-3.5-turbo
        """
    )
    parser.add_argument(
        "-i", "--input",
        default=DEFAULT_INPUT,
        help=f"Input bookmarks JSON file (default: {DEFAULT_INPUT})"
    )
    parser.add_argument(
        "-o", "--output",
        default=DEFAULT_OUTPUT,
        help=f"Output organized JSON file (default: {DEFAULT_OUTPUT})"
    )
    parser.add_argument(
        "-b", "--batch-size",
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help=f"Number of bookmarks per API call (default: {DEFAULT_BATCH_SIZE})"
    )
    parser.add_argument(
        "-m", "--model",
        default=DEFAULT_MODEL,
        help=f"OpenAI model to use (default: {DEFAULT_MODEL})"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview bookmarks without making API calls"
    )
    parser.add_argument(
        "--api-key",
        default=os.getenv("OPENAI_API_KEY"),
        help="OpenAI API key (or set OPENAI_API_KEY in .env)"
    )
    parser.add_argument(
        "--merge",
        action="store_true",
        help="Merge results into existing output file instead of overwriting"
    )
    return parser.parse_args()


def load_bookmarks(file_path: str) -> list:
    """Load bookmarks from JSON file."""
    print(f"[INFO] Loading bookmarks from: {file_path}")
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            bookmarks = json.load(f)
        print(f"[INFO] Loaded {len(bookmarks)} bookmarks.")
        return bookmarks
    except FileNotFoundError:
        print(f"[ERROR] File not found: {file_path}")
        sys.exit(1)
    except json.JSONDecodeError as e:
        print(f"[ERROR] Invalid JSON in {file_path}: {e}")
        sys.exit(1)


def format_bookmarks_for_prompt(bookmarks: list) -> str:
    """Format bookmarks list for API prompt."""
    lines = [f'"{b.get("name", "Untitled")}" - {b.get("url", "")}' for b in bookmarks]
    return "\n".join(lines)


def create_prompt(bookmarks_text: str) -> str:
    """Create the organization prompt."""
    return f"""
You are an expert at organizing information. I have a list of Chrome bookmarks.

Each line has a bookmark with a name and a URL. Please group them into logical folders based on category or topic.

Output JSON in this format:
{{
  "Folder Name": [{{"name": "...", "url": "..."}}],
  "Another Folder": [{{"name": "...", "url": "..."}}]
}}

Important:
- Create meaningful folder names based on the content
- Group similar items together (e.g., all shopping sites, all news, all dev tools)
- If a bookmark doesn't fit anywhere, put it in "Miscellaneous"
- Preserve the original bookmark names and URLs exactly

Bookmarks:
{bookmarks_text}
"""


def organize_batch(client: OpenAI, bookmarks: list, model: str) -> dict:
    """Send a batch of bookmarks to the API for organization."""
    bookmarks_text = format_bookmarks_for_prompt(bookmarks)
    prompt = create_prompt(bookmarks_text)

    response = client.chat.completions.create(
        model=model,
        messages=[
            {"role": "system", "content": "You are a helpful assistant that organizes bookmarks. Always respond with valid JSON."},
            {"role": "user", "content": prompt}
        ],
        temperature=0.4,
        timeout=120
    )

    content = response.choices[0].message.content.strip()

    # Try to extract JSON from the response
    # Handle cases where the model wraps JSON in markdown code blocks
    if content.startswith("```"):
        lines = content.split("\n")
        # Remove first and last lines (```json and ```)
        content = "\n".join(lines[1:-1])

    return json.loads(content)


def merge_organized(existing: dict, new: dict) -> dict:
    """Merge new organized bookmarks into existing structure."""
    for folder, bookmarks in new.items():
        if folder in existing:
            # Avoid duplicates by URL
            existing_urls = {b["url"] for b in existing[folder]}
            for bookmark in bookmarks:
                if bookmark["url"] not in existing_urls:
                    existing[folder].append(bookmark)
        else:
            existing[folder] = bookmarks
    return existing


def dry_run_preview(bookmarks: list, batch_size: int):
    """Preview what would be processed without making API calls."""
    print("\n[DRY RUN] Preview of bookmarks to be processed:")
    print("=" * 60)

    total_batches = (len(bookmarks) + batch_size - 1) // batch_size
    print(f"Total bookmarks: {len(bookmarks)}")
    print(f"Batch size: {batch_size}")
    print(f"Total batches: {total_batches}")
    print()

    for i, batch_start in enumerate(range(0, len(bookmarks), batch_size)):
        batch = bookmarks[batch_start:batch_start + batch_size]
        print(f"Batch {i + 1}/{total_batches} ({len(batch)} bookmarks):")
        for j, b in enumerate(batch[:5]):  # Show first 5 of each batch
            print(f"  {j + 1}. {b.get('name', 'Untitled')[:50]}")
        if len(batch) > 5:
            print(f"  ... and {len(batch) - 5} more")
        print()

    print("[DRY RUN] No API calls were made. Remove --dry-run to process.")


def main():
    args = parse_args()

    print("[START] Bookmarks AI Organizer v2")

    # Validate API key (unless dry run)
    if not args.dry_run and not args.api_key:
        print("[ERROR] OpenAI API key required. Set OPENAI_API_KEY in .env or use --api-key")
        sys.exit(1)

    # Load bookmarks
    bookmarks = load_bookmarks(args.input)

    if not bookmarks:
        print("[ERROR] No bookmarks found in input file.")
        sys.exit(1)

    # Dry run mode
    if args.dry_run:
        dry_run_preview(bookmarks, args.batch_size)
        return

    # Initialize OpenAI client
    client = OpenAI(api_key=args.api_key)

    # Load existing output if merging
    organized = {}
    if args.merge and Path(args.output).exists():
        try:
            with open(args.output, "r", encoding="utf-8") as f:
                organized = json.load(f)
            print(f"[INFO] Loaded existing organized bookmarks with {len(organized)} folders")
        except Exception as e:
            print(f"[WARN] Could not load existing output: {e}")

    # Process in batches
    total_batches = (len(bookmarks) + args.batch_size - 1) // args.batch_size
    print(f"[INFO] Processing {len(bookmarks)} bookmarks in {total_batches} batches...")

    for i, batch_start in enumerate(range(0, len(bookmarks), args.batch_size)):
        batch = bookmarks[batch_start:batch_start + args.batch_size]
        batch_num = i + 1

        print(f"[INFO] Processing batch {batch_num}/{total_batches} ({len(batch)} bookmarks)...")

        try:
            batch_result = organize_batch(client, batch, args.model)
            organized = merge_organized(organized, batch_result)
            print(f"[INFO] Batch {batch_num} completed. Current folders: {len(organized)}")
        except json.JSONDecodeError as e:
            print(f"[ERROR] Batch {batch_num} returned invalid JSON: {e}")
            continue
        except Exception as e:
            print(f"[ERROR] Batch {batch_num} failed: {e}")
            continue

    # Save results
    if organized:
        try:
            with open(args.output, "w", encoding="utf-8") as f:
                json.dump(organized, f, indent=2, ensure_ascii=False)
            print(f"[SUCCESS] Organized bookmarks saved to: {args.output}")

            # Print summary
            print("\n[SUMMARY] Folder breakdown:")
            for folder, items in sorted(organized.items(), key=lambda x: -len(x[1])):
                print(f"  {folder}: {len(items)} bookmarks")
        except Exception as e:
            print(f"[ERROR] Failed to save output: {e}")
    else:
        print("[WARNING] No organized bookmarks to save.")


if __name__ == "__main__":
    main()

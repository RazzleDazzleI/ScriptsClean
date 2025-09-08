import os
import csv
import re

def extract_metadata(filepath):
    try:
        with open(filepath, "r", encoding="utf-8") as f:
            lines = f.readlines()
            if not lines:
                return None  # skip empty
            # Simple metadata example: first line is assumed to be title
            title = lines[0].strip()
            word_count = sum(len(line.split()) for line in lines)
            return {
                "Filename": os.path.basename(filepath),
                "Title": title,
                "Word Count": word_count
            }
    except Exception as e:
        raise RuntimeError(f"{os.path.basename(filepath)} — {e}")

def rebuild_index(folder, output_csv):
    entries = []
    errors = []
    for root, dirs, files in os.walk(folder):
        for file in files:
            if file.endswith(".txt"):
                filepath = os.path.join(root, file)
                try:
                    meta = extract_metadata(filepath)
                    if meta:
                        meta["Space"] = os.path.basename(root)
                        entries.append(meta)
                except Exception as e:
                    errors.append(str(e))
    
    with open(output_csv, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=["Space", "Filename", "Title", "Word Count"])
        writer.writeheader()
        writer.writerows(entries)
    
    print(f"Rebuilt index with {len(entries)} entries at: {output_csv}")
    if errors:
        with open("confluence_index_errors.log", "w", encoding="utf-8") as errlog:
            for e in errors:
                errlog.write(e + "\n")
        print(f"⚠️ Logged {len(errors)} errors to confluence_index_errors.log")

if __name__ == "__main__":
    rebuild_index("confluence_pages", "confluence_pages/confluence_index.csv")

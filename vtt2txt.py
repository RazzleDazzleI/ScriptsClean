# vtt2txt.py
import re, os, sys, glob

def vtt_to_text(vtt_path: str) -> str:
    with open(vtt_path, 'r', encoding='utf-8', errors='ignore') as f:
        txt = f.read()

    lines = []
    for line in txt.splitlines():
        line = line.strip()
        if not line or line == 'WEBVTT' or '-->' in line or line.isdigit():
            continue
        line = re.sub(r'<[^>]+>', '', line)            # strip HTML tags
        line = re.sub(r'\[(Music|Applause|Laughter)\]', '', line, flags=re.I)  # optional noise
        lines.append(line)

    # Collapse to paragraphs
    out = re.sub(r'\s+', ' ', ' '.join(lines)).strip()
    return out

def main():
    if len(sys.argv) > 1:
        vtt = sys.argv[1]
    else:
        # pick the newest English subtitle in the current folder
        candidates = glob.glob('*.en.vtt') or glob.glob('*.vtt')
        if not candidates:
            print('No .vtt files found'); sys.exit(1)
        vtt = max(candidates, key=os.path.getmtime)

    base, _ = os.path.splitext(vtt)
    out_path = base + '.txt'
    with open(out_path, 'w', encoding='utf-8') as f:
        f.write(vtt_to_text(vtt))
    print('Wrote', out_path)

if __name__ == '__main__':
    main()

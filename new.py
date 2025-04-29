#!/usr/bin/env python3

import argparse
import hashlib
import os
import sys
from datetime import datetime
from pathlib import Path

# ───── Color Constants ─────
RED = '\033[0;31m'
GREEN = '\033[0;32m'
YELLOW = '\033[1;33m'
NC = '\033[0m'  # No Color

# ───── Logging Functions ─────
def log_info(msg): print(f"{GREEN}[INFO]{NC} {msg}")
def log_warn(msg): print(f"{YELLOW}[WARN]{NC} {msg}")
def log_error(msg): print(f"{RED}[ERROR]{NC} {msg}", file=sys.stderr)

# ───── Supported Algorithms ─────
HASH_ALGOS = {
    'sha256': hashlib.sha256,
    'sha1': hashlib.sha1,
    'md5': hashlib.md5
}

def hash_file(filepath, algo_func):
    hasher = algo_func()
    try:
        with open(filepath, 'rb') as f:
            while chunk := f.read(8192):
                hasher.update(chunk)
        return hasher.hexdigest()
    except Exception as e:
        log_error(f"Failed to hash {filepath}: {e}")
        return None

def collect_files(paths):
    files = []
    for path in paths:
        p = Path(path)
        if p.is_dir():
            files.extend([str(f) for f in p.rglob('*') if f.is_file()])
        elif p.is_file():
            files.append(str(p))
        else:
            log_error(f"Invalid path: {path}")
    return files

def main():
    parser = argparse.ArgumentParser(description="Hash files or directories recursively.")
    parser.add_argument("paths", nargs='+', help="Files or directories to hash")
    parser.add_argument("--output", "-o", default=f"hasher-{datetime.now().date()}.txt", help="Output log file")
    parser.add_argument("--algo", choices=HASH_ALGOS.keys(), default="sha256", help="Hash algorithm to use")

    args = parser.parse_args()

    algo_func = HASH_ALGOS[args.algo]
    all_files = collect_files(args.paths)

    if not all_files:
        log_error("No valid files found.")
        sys.exit(1)

    total = len(all_files)
    with open(args.output, 'a') as out:
        for i, file in enumerate(all_files, start=1):
            print(f"[{i}/{total}] Processing: {file}")
            hash_val = hash_file(file, algo_func)
            if not hash_val:
                continue
            file_type = os.popen(f'file -b "{file}"').read().strip()
            now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            cwd = os.getcwd()
            log_info(f"Hashed '{file}'")
            log_line = f"[{now}] File: '{file}' | Hash ({args.algo}): {hash_val} | Type: {file_type} | Dir: {cwd}\n"
            out.write(log_line)
            print(log_line, end='')

if __name__ == "__main__":
    main()

## invoke using
## python3 hasher.py file1.txt folder2
## python3 hasher.py --algo sha1 --output myhashes.txt /etc

#!/usr/bin/env python3
"""
Standalone OpenWrt APK archive extractor with strict root confinement,
multi-stream gzip decompression, zero padding tolerance, and path traversal defense.
"""

import io
import os
import stat
import sys
import tarfile
import zlib

GZIP_MAGIC = bytes.fromhex("1f8b")


def decompress_apk_streams(apk_path):
    if not os.path.isfile(apk_path):
        raise FileNotFoundError(f"APK file not found: {apk_path}")

    file_size = os.path.getsize(apk_path)
    if file_size == 0:
        raise ValueError(f"APK file is empty: {apk_path}")

    with open(apk_path, "rb") as f:
        raw_data = f.read()

    chunks = []
    cur = raw_data

    while cur:
        idx = cur.find(GZIP_MAGIC)
        if idx == -1:
            break
        cur = cur[idx:]
        d = zlib.decompressobj(16 + zlib.MAX_WBITS)
        try:
            decompressed = d.decompress(cur)
            if decompressed:
                chunks.append(decompressed)
            cur = d.unused_data
        except zlib.error:
            cur = cur[2:]

    if not chunks:
        raise ValueError(f"No valid gzip streams found in APK: {apk_path}")

    return chunks


def safe_extract_tar_stream(tar_bytes, dest_dir, extracted_files):
    dest_canon = os.path.realpath(dest_dir)

    with tarfile.open(fileobj=io.BytesIO(tar_bytes), mode="r:") as t:
        for m in t.getmembers():
            # 1. Normalize member path (strip leading slashes, convert backslashes)
            clean_rel = m.name.replace("\\", "/").lstrip("/")
            if not clean_rel:
                continue

            # 2. Prevent path traversal using canonical resolution
            target_path = os.path.abspath(os.path.join(dest_canon, clean_rel))
            target_dir_path = os.path.dirname(target_path)

            try:
                common = os.path.commonpath([dest_canon, target_path])
            except ValueError:
                sys.stderr.write(f"[WARN] Rejected traversal entry across drives: {m.name}\n")
                continue

            if common != dest_canon:
                sys.stderr.write(f"[WARN] Rejected traversal entry: {m.name} -> {target_path}\n")
                continue

            # 3. Handle member types safely
            if m.isdir():
                os.makedirs(target_path, exist_ok=True)
            elif m.isreg():
                os.makedirs(target_dir_path, exist_ok=True)
                f = t.extractfile(m)
                if f is not None:
                    with open(target_path, "wb") as out_f:
                        out_f.write(f.read())
                    if m.mode is not None and m.mode != 0:
                        try:
                            os.chmod(target_path, m.mode & 0o777)
                        except OSError:
                            pass
                    extracted_files.append(target_path)
            elif m.issym():
                link_target = m.linkname
                if link_target.startswith("/"):
                    # Absolute symlink (e.g. /opt/xray/current/xray) - created as-is
                    os.makedirs(target_dir_path, exist_ok=True)
                    if os.path.islink(target_path) or os.path.exists(target_path):
                        try:
                            os.unlink(target_path)
                        except OSError:
                            pass
                    try:
                        os.symlink(link_target, target_path)
                    except OSError:
                        pass
                else:
                    # Relative symlink - verify target does not escape destination
                    link_abs = os.path.abspath(os.path.join(target_dir_path, link_target))
                    try:
                        link_common = os.path.commonpath([dest_canon, link_abs])
                    except ValueError:
                        link_common = None

                    if link_common == dest_canon:
                        os.makedirs(target_dir_path, exist_ok=True)
                        if os.path.islink(target_path) or os.path.exists(target_path):
                            try:
                                os.unlink(target_path)
                            except OSError:
                                pass
                        try:
                            os.symlink(link_target, target_path)
                        except OSError:
                            pass
                    else:
                        sys.stderr.write(f"[WARN] Rejected escaping relative symlink: {m.name} -> {link_target}\n")
            else:
                sys.stderr.write(f"[WARN] Skipped unsupported entry type for: {m.name}\n")


def extract_openwrt_apk(apk_path, dest_dir):
    dest_canon = os.path.realpath(dest_dir)
    os.makedirs(dest_canon, exist_ok=True)

    streams = decompress_apk_streams(apk_path)
    extracted_files = []

    for stream in streams:
        safe_extract_tar_stream(stream, dest_canon, extracted_files)

    if not extracted_files:
        raise RuntimeError(f"Zero regular files extracted from APK: {apk_path}")

    return extracted_files


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("Usage: extract_openwrt_apk.py apk_path dest_dir\n")
        sys.exit(2)

    apk_path = sys.argv[1]
    dest_dir = sys.argv[2]

    try:
        extracted = extract_openwrt_apk(apk_path, dest_dir)
        print(f"Successfully extracted {len(extracted)} files to {dest_dir}")
        sys.exit(0)
    except Exception as err:
        sys.stderr.write(f"[ERROR] APK extraction failed: {err}\n")
        sys.exit(1)


if __name__ == "__main__":
    main()

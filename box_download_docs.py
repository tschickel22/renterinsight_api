#!/usr/bin/env python3
"""
Box Document Explorer & Downloader
Downloads PDFs, XLSXs, and docs from Champion Homes Box shared links
for Topeka IN and Decatur IN factories.
"""

import os, sys, json, time, requests, re
from pathlib import Path

BOX_TOKEN = os.environ.get("BOX_TOKEN", "").strip()
if not BOX_TOKEN:
    print("ERROR: Set BOX_TOKEN env var"); sys.exit(1)

DOWNLOAD_DIR = Path("box_downloads")
DOWNLOAD_DIR.mkdir(exist_ok=True)

# Document extensions we care about
DOC_EXTENSIONS = {".pdf", ".xlsx", ".xls", ".csv", ".doc", ".docx", ".txt"}

# Two shared links
SHARES = [
    {
        "name": "Topeka IN",
        "share_token": "u33mdm87brnjb9onk864w3cttlttw16d",
        "share_url": "https://championh.box.com/s/u33mdm87brnjb9onk864w3cttlttw16d",
        "download_subdir": "topeka-in",
    },
    {
        "name": "Decatur IN",
        "share_token": "v9aad8t9g79eqog9k3fcjpnvhgj7ci8x",
        "share_url": "https://championh.box.com/s/v9aad8t9g79eqog9k3fcjpnvhgj7ci8x",
        "download_subdir": "decatur-in",
    },
]

session = requests.Session()
session.headers.update({"User-Agent": "Mozilla/5.0"})

def box_get_shared_item(share_url):
    """Get the root folder info for a shared link"""
    url = "https://api.box.com/2.0/shared_items"
    headers = {
        "Authorization": f"Bearer {BOX_TOKEN}",
        "BoxApi": f"shared_link={share_url}",
    }
    resp = session.get(url, headers=headers, timeout=30)
    resp.raise_for_status()
    return resp.json()

def box_list_folder(folder_id, share_url, offset=0, limit=1000):
    """List items in a Box folder"""
    url = f"https://api.box.com/2.0/folders/{folder_id}/items"
    headers = {
        "Authorization": f"Bearer {BOX_TOKEN}",
        "BoxApi": f"shared_link={share_url}",
    }
    params = {"fields": "id,name,type,size,modified_at", "limit": limit, "offset": offset}
    resp = session.get(url, headers=headers, params=params, timeout=30)
    resp.raise_for_status()
    time.sleep(0.3)
    return resp.json()

def box_download_file(file_id, share_url, local_path):
    """Download a file from Box"""
    url = f"https://api.box.com/2.0/files/{file_id}/content"
    headers = {
        "Authorization": f"Bearer {BOX_TOKEN}",
        "BoxApi": f"shared_link={share_url}",
    }
    resp = session.get(url, headers=headers, allow_redirects=True, timeout=120, stream=True)
    resp.raise_for_status()

    local_path.parent.mkdir(parents=True, exist_ok=True)
    with open(local_path, "wb") as f:
        for chunk in resp.iter_content(chunk_size=8192):
            f.write(chunk)

    return local_path.stat().st_size

def is_document(filename):
    """Check if file is a document we want"""
    return Path(filename).suffix.lower() in DOC_EXTENSIONS

def explore_folder(folder_id, share_url, path_parts=None, depth=0, max_depth=4):
    """Recursively explore folder, collecting document files"""
    if path_parts is None:
        path_parts = []
    if depth > max_depth:
        return []

    docs = []
    result = box_list_folder(folder_id, share_url)
    entries = result.get("entries", [])

    for entry in entries:
        name = entry["name"]
        entry_type = entry["type"]

        if entry_type == "file":
            if is_document(name):
                docs.append({
                    "file_id": entry["id"],
                    "filename": name,
                    "size": entry.get("size", 0),
                    "path": "/".join(path_parts + [name]),
                    "folder_path": "/".join(path_parts),
                    "modified_at": entry.get("modified_at", ""),
                })
        elif entry_type == "folder":
            # Skip image-only folders to save time (we already have those on S3)
            lower_name = name.lower()
            skip_keywords = ["web ", "jpgs", "videos", " jpgs", " web"]
            # Only skip if it's a leaf-level media folder (depth > 2)
            if depth > 2 and any(kw in lower_name for kw in skip_keywords):
                continue

            print(f"{'  ' * depth}📁 {name}")
            sub_docs = explore_folder(
                entry["id"], share_url,
                path_parts + [name], depth + 1, max_depth
            )
            docs.extend(sub_docs)

    return docs

def main():
    print("=" * 60)
    print("Box Document Explorer & Downloader")
    print("=" * 60)

    all_docs = {}

    for share in SHARES:
        print(f"\n{'=' * 50}")
        print(f"📦 {share['name']}")
        print(f"{'=' * 50}")

        try:
            # Get root folder
            root = box_get_shared_item(share["share_url"])
            root_id = root["id"]
            root_name = root.get("name", "unknown")
            print(f"Root: {root_name} (id: {root_id})")

            # Explore recursively
            docs = explore_folder(root_id, share["share_url"])

            print(f"\n📄 Found {len(docs)} documents:")
            for i, doc in enumerate(docs, 1):
                size_kb = doc["size"] / 1024
                ext = Path(doc["filename"]).suffix.lower()
                print(f"  {i:2d}. [{ext:5s}] {doc['path']:<70s} ({size_kb:.0f} KB)")

            all_docs[share["name"]] = {
                "share_url": share["share_url"],
                "subdir": share["download_subdir"],
                "docs": docs,
            }

        except Exception as e:
            print(f"❌ Error exploring {share['name']}: {e}")
            import traceback; traceback.print_exc()

    # Save index
    index_path = DOWNLOAD_DIR / "document_index.json"
    with open(index_path, "w") as f:
        json.dump(all_docs, f, indent=2)
    print(f"\n📋 Document index saved to {index_path}")

    # Download all documents
    total = sum(len(v["docs"]) for v in all_docs.values())
    print(f"\n{'=' * 50}")
    print(f"⬇️  Downloading {total} documents...")
    print(f"{'=' * 50}")

    success = fail = skip = 0
    for share_name, share_data in all_docs.items():
        subdir = share_data["subdir"]
        share_url_val = share_data["share_url"]

        for doc in share_data["docs"]:
            local_path = DOWNLOAD_DIR / subdir / doc["path"]

            if local_path.exists() and local_path.stat().st_size > 0:
                print(f"  ⏭  {doc['filename']} (already downloaded)")
                skip += 1
                continue

            try:
                size = box_download_file(doc["file_id"], share_url_val, local_path)
                print(f"  ✅ {doc['filename']} ({size/1024:.0f} KB)")
                success += 1
            except Exception as e:
                print(f"  ❌ {doc['filename']}: {e}")
                fail += 1

    print(f"\n{'=' * 50}")
    print(f"DONE: ✅ {success} downloaded, ⏭ {skip} skipped, ❌ {fail} failed")
    print(f"Files in: {DOWNLOAD_DIR.absolute()}")
    print(f"{'=' * 50}")

if __name__ == "__main__":
    main()

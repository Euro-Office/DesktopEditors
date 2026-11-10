#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Euro-Office contributors
# SPDX-License-Identifier: AGPL-3.0-only
"""Update feeds (appcasts) for Sparkle (macOS) and WinSparkle (Windows).

  appcast.py genkey
      Prints a new Ed25519 key pair: the private key goes into a secret, the
      public key into the build (SUPublicEDKey / EO_UPDATE_PUBLIC_KEY).

  appcast.py feed --brand euro-office --version 9.3.8rc.1 --short-version 9.3.8
                  --release-assets assets.json --out DIR FILE...
      Signs the update files with the private key from UPDATE_PRIVATE_KEY and
      writes <brand>-appcast-macos.xml (from *-macos-*.dmg) and
      <brand>-appcast-windows.xml (from *-windows-{x64,arm64}.exe) into DIR.
      --version must be the update version the build has (CFBundleVersion /
      EO_UPDATE_VERSION). assets.json is the release's asset list
      (gh api repos/<repo>/releases/tags/<tag> --jq .assets); each file's
      download URL is the asset with the same SHA-256, since GitHub renames
      some files on upload (~ becomes .).

Needs the "cryptography" package.
"""

import argparse
import base64
import email.utils
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
MACOS_MINIMUM = "13.0"  # CEF 156


def load_private_key(text: str) -> Ed25519PrivateKey:
    raw = base64.b64decode(text.strip())
    # 32-byte seed, or seed + public key as older Sparkle tools export it
    if len(raw) not in (32, 64):
        sys.exit(f"private key has {len(raw)} bytes, expected 32 or 64")
    return Ed25519PrivateKey.from_private_bytes(raw[:32])


def public_key_b64(key: Ed25519PrivateKey) -> str:
    raw = key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    return base64.b64encode(raw).decode()


def genkey(_args):
    key = Ed25519PrivateKey.generate()
    seed = key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw,
                             serialization.NoEncryption())
    print(f"private: {base64.b64encode(seed).decode()}")
    print(f"public:  {public_key_b64(key)}")


def enclosure(path: Path, urls: dict, key: Ed25519PrivateKey, **extra) -> str:
    data = path.read_bytes()
    url = urls.get("sha256:" + hashlib.sha256(data).hexdigest())
    if not url:
        sys.exit(f"{path.name} is not among the release's assets")
    attrs = {
        "url": url,
        "length": str(path.stat().st_size),
        "type": "application/octet-stream",
        "sparkle:edSignature": base64.b64encode(key.sign(data)).decode(),
        **extra,
    }
    return "<enclosure " + " ".join(f"{k}={quoteattr(v)}" for k, v in attrs.items()) + "/>"


def write_feed(out: Path, title: str, version: str, short_version: str, item_extra: str, enclosures):
    out.write_text(f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{SPARKLE_NS}">
  <channel>
    <title>{escape(title)}</title>
    <item>
      <title>{escape(short_version)}</title>
      <pubDate>{email.utils.formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{escape(version)}</sparkle:version>
      <sparkle:shortVersionString>{escape(short_version)}</sparkle:shortVersionString>{item_extra}
      {(chr(10) + '      ').join(enclosures)}
    </item>
  </channel>
</rss>
""", encoding="utf-8")
    print(f"wrote {out}")


def feed(args):
    key_text = os.environ.get("UPDATE_PRIVATE_KEY", "")
    if not key_text:
        sys.exit("UPDATE_PRIVATE_KEY is not set")
    key = load_private_key(key_text)
    if args.public_key and args.public_key != public_key_b64(key):
        sys.exit("UPDATE_PRIVATE_KEY doesn't match --public-key")

    files = [Path(f) for f in args.files]
    dmgs = [f for f in files if re.search(r"-macos-[^/]*\.dmg$", f.name)]
    exes = [(f, m.group(1)) for f in files if (m := re.search(r"-windows-(x64|arm64)\.exe$", f.name))]
    if not dmgs and not exes:
        sys.exit("no *-macos-*.dmg or *-windows-{x64,arm64}.exe among the files")
    if len(dmgs) > 1:
        sys.exit(f"more than one macOS update: {', '.join(f.name for f in dmgs)}")

    urls = {a["digest"]: a["browser_download_url"]
            for a in json.loads(Path(args.release_assets).read_text()) if a.get("digest")}

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    if dmgs:
        write_feed(out / f"{args.brand}-appcast-macos.xml", args.title or args.brand, args.version,
                   args.short_version,
                   f"\n      <sparkle:minimumSystemVersion>{MACOS_MINIMUM}</sparkle:minimumSystemVersion>",
                   [enclosure(dmgs[0], urls, key)])
    if exes:
        # One item, WinSparkle picks the enclosure for its architecture
        write_feed(out / f"{args.brand}-appcast-windows.xml", args.title or args.brand, args.version,
                   args.short_version, "",
                   [enclosure(f, urls, key, **{"sparkle:os": f"windows-{arch}"})
                    for f, arch in sorted(exes, key=lambda e: e[1])])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("genkey").set_defaults(func=genkey)
    p = sub.add_parser("feed")
    p.add_argument("--brand", required=True)
    p.add_argument("--title")
    p.add_argument("--version", required=True)
    p.add_argument("--short-version", required=True)
    p.add_argument("--release-assets", required=True, help="JSON asset list of the release")
    p.add_argument("--public-key", help="fail unless the private key belongs to this public key")
    p.add_argument("--out", required=True)
    p.add_argument("files", nargs="+")
    p.set_defaults(func=feed)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

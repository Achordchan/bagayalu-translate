#!/usr/bin/env python3
"""桥接发布用：验证 Sparkle 签名，并写出只含一个更新项的 appcast.xml。

签名由 Sparkle 官方的 sign_update 完成；这里只做两件事：
1. 用本仓库 Configuration/App-Info.plist 里的 SUPublicEDKey 验证签名，私钥不对就拒绝输出；
2. 把 zip 的下载地址、长度、签名和发布说明写成 appcast。
"""
import argparse
import base64
import html
import sys
from email.utils import formatdate
from pathlib import Path

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--zip", required=True, type=Path)
    ap.add_argument("--version", required=True)
    ap.add_argument("--build", required=True)
    ap.add_argument("--url", required=True)
    ap.add_argument("--notes", required=True, type=Path)
    ap.add_argument("--signature", required=True, help="sign_update 输出的 base64 签名")
    ap.add_argument("--pub", required=True, help="SUPublicEDKey（base64）")
    ap.add_argument("--min-os", default="13.0")
    ap.add_argument("--out", required=True, type=Path)
    a = ap.parse_args()

    data = a.zip.read_bytes()
    try:
        Ed25519PublicKey.from_public_bytes(base64.b64decode(a.pub)).verify(base64.b64decode(a.signature), data)
    except (InvalidSignature, ValueError) as e:
        print(f"签名与应用内置的 SUPublicEDKey 不匹配，已拒绝输出：{e!r}", file=sys.stderr)
        return 1

    notes = html.escape(a.notes.read_text(encoding="utf-8")).replace("]]>", "]]]]><![CDATA[>")
    esc = html.escape
    a.out.write_text(
        f'''<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
  <channel>
    <title>Tolk</title>
    <item>
      <title>{esc(a.version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{esc(a.build)}</sparkle:version>
      <sparkle:shortVersionString>{esc(a.version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{esc(a.min_os)}</sparkle:minimumSystemVersion>
      <description><![CDATA[<pre>{notes}</pre>]]></description>
      <enclosure url="{esc(a.url)}" length="{len(data)}" type="application/octet-stream" sparkle:edSignature="{esc(a.signature)}"/>
    </item>
  </channel>
</rss>
''',
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())

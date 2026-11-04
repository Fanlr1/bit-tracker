#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""prototype-snapshot.py -- 用无头 Edge/Chrome 给 tools/prototype.html 拍一组验证截图。

用法:
    python tools/prototype-snapshot.py                # 生成全套到 tools/shots/
    python tools/prototype-snapshot.py --out DIR      # 指定输出目录
    python tools/prototype-snapshot.py --only title   # 只拍一张

原理: 调浏览器的 --headless=new --screenshot，页面用 URL 参数进入指定状态
      (?auto=..., &ff=秒, &static=1 只画一帧)，所以截图是确定性的、可复现。
不需要 PIL；浏览器不存在时会打印提示（也可以直接双击 HTML 手动玩/截图）。
"""
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.parse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HTML = os.path.join(ROOT, "tools", "prototype.html")
DEFAULT_OUT = os.path.join(ROOT, "tools", "shots")

BROWSERS = [
    r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
    r"C:\Program Files\Google\Chrome\Application\chrome.exe",
    r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
]

SHOTS = [
    ("01-title",        "?auto=title&static=1"),
    ("02-play-45s",     "?auto=play&ff=45&static=1"),
    ("03-play-120s",    "?auto=play&ff=120&static=1"),
    ("04-upgrade",      "?auto=upgrade&ff=40&static=1"),
    ("05-pause",        "?auto=pause&ff=30&static=1"),
    ("06-over",         "?auto=over&ff=30&static=1"),
    ("07-debug-f1",     "?auto=play&ff=60&static=1&dbg=1"),
    ("08-sprite-sheet", "?sprite=1"),
    ("09-help",         "?auto=title&static=1&help=1"),
    ("10-stress-pool",  "?auto=play&ff=30&stress=1&static=1&dbg=1"),
]


def find_browser():
    for b in BROWSERS:
        if os.path.isfile(b):
            return b
    for name in ("msedge", "chrome", "chromium"):
        p = shutil.which(name)
        if p:
            return p
    return None


def main():
    args = sys.argv[1:]
    out = DEFAULT_OUT
    only = None
    for i, a in enumerate(args):
        if a == "--out" and i + 1 < len(args):
            out = os.path.abspath(args[i + 1])
        elif a == "--only" and i + 1 < len(args):
            only = args[i + 1]
    os.makedirs(out, exist_ok=True)

    browser = find_browser()
    if not browser:
        print("找不到 Edge/Chrome，无法自动截图。")
        print("手动做法：双击 tools/prototype.html，按需求里的按键玩/截图。")
        return 2
    if not os.path.isfile(HTML):
        print("找不到 " + HTML)
        return 2

    profile = os.path.join(tempfile.gettempdir(), "gfx1408-proto-snap")
    base = "file:///" + urllib.parse.quote(HTML.replace(os.sep, "/"))
    ok = 0
    for name, query in SHOTS:
        if only and only not in name:
            continue
        dst = os.path.join(out, name + ".png")
        if os.path.exists(dst):
            os.remove(dst)
        cmd = [
            browser, "--headless=new", "--disable-gpu", "--no-sandbox",
            "--hide-scrollbars", "--window-size=1920,1080",
            "--virtual-time-budget=8000", "--user-data-dir=" + profile,
            "--screenshot=" + dst, base + query,
        ]
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                          timeout=180, cwd=ROOT)
        if os.path.exists(dst) and os.path.getsize(dst) > 2000:
            print("OK   %-16s %7d B  %s" % (name, os.path.getsize(dst), query))
            ok += 1
        else:
            print("FAIL %-16s %s" % (name, r.stdout.decode("utf-8", "replace")[-400:]))
    print("生成 %d 张 -> %s" % (ok, out))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

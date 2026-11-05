#!/usr/bin/env python3
"""Records the README's GIF from a real run: `dsh-romeo --launch` typed in a terminal, then the dsh Web UI it
opens, where an agent fixes a failing test in the chat, then the Trajectory tab of that session.

    python tests/demo.py record --dir /tmp/dsh-demo    # real run: launches a model job on ROMEO
    python tests/demo.py web --url URL                 # only the Web UI part, against a running dsh web
    python tests/demo.py render                        # img/dsh-romeo.gif from tests/demo-frames/

Needs pyte, Pillow and Playwright with Chromium (pip install pyte pillow playwright; python -m playwright install
chromium). `record` runs bash in a pseudo-terminal inside --dir (a small project with a failing test), types the
command and keeps the screen while the model loads. A stand-in `open` first in PATH catches the URL dsh web hands to
the browser; Playwright's Chromium opens it, types the task, keeps a screenshot every second until the agent is done,
then opens the Trajectory tab. The token of the URL is masked in the frames.
"""

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import stat
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from tui import BACKGROUND, Term, render_png  # noqa: E402

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FRAMES = os.path.join(REPO, "tests", "demo-frames")
WIDTH, HEIGHT = 1280, 760                   # browser viewport; terminal frames are drawn to the same size
COLS, ROWS = 106, 30                        # terminal of 12 x 25 px cells
COMMAND = "dsh-romeo --launch"
TASK = "Run the tests with python3 -m unittest, fix the bug, and run them again."


class Recorder:
    """Frames as PNG files plus an index: [file, milliseconds shown, kind]."""

    def __init__(self):
        shutil.rmtree(FRAMES, ignore_errors=True)
        os.makedirs(FRAMES)
        self.index = []
        self.last = None

    def add(self, image, ms, kind="normal"):
        digest = hashlib.md5(image.tobytes()).hexdigest()
        if digest == self.last and self.index:     # same picture: show the previous frame longer
            self.index[-1][1] += ms
            self.save()
            return
        self.last = digest
        name = "%04d.png" % len(self.index)
        image.save(os.path.join(FRAMES, name))
        self.index.append([name, ms, kind])
        self.save()                                # kept on disk as we go: a crash keeps the frames usable

    def save(self):
        with open(os.path.join(FRAMES, "index.json"), "w") as f:
            json.dump(self.index, f)


def masked(cells):
    """The terminal cells with the token of any URL replaced by dots."""
    out = []
    for row in cells:
        text = "".join(c[0] for c in row)
        row = list(row)
        for m in re.finditer(r"token=(\S+)", text):
            for x in range(m.start(1), m.end(1)):
                row[x] = ("•",) + tuple(row[x][1:])
        out.append(row)
    return out


def terminal_image(term):
    from PIL import Image
    img = render_png(masked(term.snapshot()), cell_w=12, cell_h=25, font_size=20)
    canvas = Image.new("RGB", (WIDTH, HEIGHT), BACKGROUND)
    canvas.paste(img, ((WIDTH - img.width) // 2, (HEIGHT - img.height) // 2))
    return canvas


def terminal_part(rec, args, url_file):
    stub = tempfile.mkdtemp(prefix="dsh-demo-open.")
    opener = os.path.join(stub, "open")
    with open(opener, "w") as f:
        f.write('#!/bin/sh\nfor a in "$@"; do case $a in http*) printf "%%s\\n" "$a" > %s ;; esac; done\n' % url_file)
    os.chmod(opener, os.stat(opener).st_mode | stat.S_IEXEC)
    env = {"PS1": "\\[\\e[1;32m\\]~/stats\\[\\e[0m\\] $ ", "HISTFILE": "/dev/null", "COLORTERM": "truecolor",
           "BASH_SILENCE_DEPRECATION_WARNING": "1", "PATH": stub + ":" + os.environ["PATH"]}
    t = Term(["bash", "--noprofile", "--norc", "-i"], cols=COLS, rows=ROWS, env=env, cwd=args.dir)
    start = time.time()

    def shot(ms, kind="normal"):
        rec.add(terminal_image(t), ms, kind)

    t.sleep(1.0)
    shot(900)
    for i, ch in enumerate(COMMAND):
        t.send(ch)
        t.sleep(0.04)
        if i % 2 == 1:
            shot(80)
    shot(700)
    t.send("enter")
    last_loading = 0.0
    deadline = time.time() + args.timeout * 60
    while time.time() < deadline and not os.path.exists(url_file):
        t.sleep(2.0)
        if "Ctrl-C stops waiting" in t.text():          # the model loads: one frame every 20 s
            if time.time() - last_loading >= 20:
                shot(500, "loading")
                last_loading = time.time()
        else:
            shot(900)
    if not os.path.exists(url_file):
        t.close()
        sys.exit("dsh web did not open its page in %d min:\n%s" % (args.timeout, t.text()))
    t.sleep(1.5)
    shot(2600)                                           # "dsh web: http://127.0.0.1:…/?token=•••", "opening the browser"
    print("terminal part: %.0f s" % (time.time() - start))
    return t


def web_part(rec, url):
    from PIL import Image
    from playwright.sync_api import sync_playwright

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": WIDTH, "height": HEIGHT}, color_scheme="dark")

        def shot(ms, kind="normal"):
            rec.add(Image.open(io.BytesIO(page.screenshot())).convert("RGB"), ms, kind)

        page.goto(url)
        page.wait_for_load_state("networkidle")
        page.wait_for_timeout(1500)
        notice = page.get_by_role("button", name="Continue")      # first-run "Preview Notice"
        if notice.count():
            notice.click()
            page.wait_for_timeout(700)
        shot(1800)
        page.locator("[contenteditable=true]").first.click()
        for i in range(0, len(TASK), 5):
            page.keyboard.type(TASK[i:i + 5], delay=15)
            shot(90)
        shot(900)
        page.keyboard.press("Enter")

        # The agent works: a screenshot every second until the page stops changing.
        start = time.time()
        last_text, last_change = "", time.time()
        while time.time() - start < 8 * 60:
            page.wait_for_timeout(1000)
            shot(450)
            text = page.locator("body").inner_text()
            if text != last_text:
                last_text, last_change = text, time.time()
            busy = page.get_by_role("button", name=re.compile("stop|cancel|interrupt", re.I)).count() > 0
            if not busy and time.time() - last_change > 12 and time.time() - start > 15:
                break
        print("agent: %.0f s" % (time.time() - start))
        shot(4000)

        # The Trajectory tab of the same session: the ledger and its timing overview, then one record.
        tab = page.get_by_role("tab", name=re.compile("Trajectory", re.I))
        if not tab.count():
            tab = page.get_by_text("Trajectory", exact=True)
        if tab.count():
            tab.first.click()
            page.wait_for_timeout(2000)
            shot(4000)
            # Open one record in the inspector: the latest "edit" call of the ledger.
            rows = [r for r in page.get_by_text("edit", exact=True).all()
                    if (box := r.bounding_box()) and box["x"] > 290 and box["y"] < HEIGHT - 170]
            if rows:
                rows[-1].click()
                page.wait_for_timeout(1800)
                shot(5500)
        else:
            print("no Trajectory tab found")
        shot(1500)
        browser.close()


def pace(ms):
    """Shown time of a frame in the GIF: typing (under 200 ms) as recorded, pauses cut to 45 %,
    at least 200 ms and at most 2.5 s, so the GIF reads in about 15 s instead of 33."""
    return ms if ms < 200 else max(200, min(2500, round(ms * 0.45)))


def render(args):
    from PIL import Image
    with open(os.path.join(FRAMES, "index.json")) as f:
        index = json.load(f)
    loading = [i for i, (_, _, kind) in enumerate(index) if kind == "loading"]
    if len(loading) > 8:                                  # the model loads for minutes: 8 frames of it
        keep = {loading[round(k * (len(loading) - 1) / 7)] for k in range(8)}
        index = [entry for i, entry in enumerate(index) if i not in loading or i in keep]
    scale = args.width / WIDTH
    images, durations = [], []
    for name, ms, _ in index:
        img = Image.open(os.path.join(FRAMES, name)).convert("RGB")
        if scale != 1:
            img = img.resize((args.width, round(HEIGHT * scale)), Image.LANCZOS)
        images.append(img.quantize(colors=128, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE))
        durations.append(pace(ms))
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    images[0].save(args.out, save_all=True, append_images=images[1:], duration=durations, loop=0, optimize=True)
    print("%s: %d frames, %.0f s, %d KB" % (args.out, len(images), sum(durations) / 1000, os.path.getsize(args.out) // 1024))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record")
    r.add_argument("--dir", default="/tmp/dsh-demo")
    r.add_argument("--timeout", type=float, default=45, help="minutes to wait for the model")
    w = sub.add_parser("web")
    w.add_argument("--url", required=True)
    d = sub.add_parser("render")
    d.add_argument("--out", default=os.path.join(REPO, "img", "dsh-romeo.gif"))
    d.add_argument("--width", type=int, default=960)
    args = p.parse_args()
    if args.cmd == "render":
        return render(args)
    rec = Recorder()
    if args.cmd == "web":
        web_part(rec, args.url)
    else:
        url_file = os.path.join(tempfile.mkdtemp(prefix="dsh-demo-url."), "url")
        term = terminal_part(rec, args, url_file)
        try:
            web_part(rec, open(url_file).read().strip())
        finally:
            term.send("ctrl-c")
            term.sleep(1.0)
            term.close()
    rec.save()
    print("%d frames in %s" % (len(rec.index), FRAMES))


if __name__ == "__main__":
    main()

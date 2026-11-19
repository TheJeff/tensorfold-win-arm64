"""Ground-truth vision probe for a running tensorfold-native server.

Why this exists next to pixel-parity.py: pixel parity proves the decoders reproduce
Pillow's bytes, and the Serve tier proves an image request gets *a* reply. Neither proves
the vision tower read the picture. A model that ignores the image entirely still produces
fluent prose, so "describe this image" measures nothing. This probe asks questions whose
answers exist only in the pixels, drawn by the same code that knows the answers, so the
truth and the image cannot drift apart.

Run against a live server (the GUI's, or one started by -Tier Serve):

    python vision-probe.py --url http://127.0.0.1:8889 [--fixtures DIR] [--card-out f.png]

Exit code is the number of failures, matching verify-engine.ps1.
"""
import argparse
import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = "C:/Windows/Fonts/arial.ttf"

fails = 0
warns = 0


def ok(msg, detail=""):
    print("  PASS  %s%s" % (msg, ("  [%s]" % detail) if detail else ""))


def bad(msg, detail=""):
    global fails
    print("  FAIL  %s  %s" % (msg, detail))
    fails += 1


def warn(msg, detail=""):
    global warns
    print("  WARN  %s  %s" % (msg, detail))


# --------------------------------------------------------------------------- the card
# Every fact here is asserted below. Keep the two lists together when editing.
def draw_card(path):
    try:
        f_large = ImageFont.truetype(FONT, 34)
        f_small = ImageFont.truetype(FONT, 14)
        f_tiny = ImageFont.truetype(FONT, 11)
    except OSError as exc:
        return None, "truetype %s failed: %s" % (FONT, exc)

    im = Image.new("RGB", (900, 600), (128, 128, 128))
    d = ImageDraw.Draw(im)
    d.rectangle([40, 40, 140, 140], fill=(200, 30, 30))
    d.rectangle([160, 40, 260, 140], fill=(30, 180, 30))
    d.rectangle([280, 40, 380, 140], fill=(30, 40, 210))
    d.text((40, 170), "QWEN VISION 2026", font=f_large, fill=(255, 255, 255))
    d.text((40, 225), "small text: kappa-17", font=f_small, fill=(0, 0, 0))
    d.text((40, 255), "7 3 9 1 5 8 2", font=f_tiny, fill=(0, 0, 0))
    gx, gy, s = 560, 60, 80
    for r in range(2):
        for c in range(2):
            x, y = gx + c * s, gy + r * s
            d.rectangle([x, y, x + s - 6, y + s - 6], fill=(245, 245, 245), outline=(0, 0, 0), width=2)
            d.text((x + 26, y + 20), str([[7, 3], [5, 9]][r][c]), font=f_large, fill=(0, 0, 0))
    import math
    cx, cy, rr = 180, 430, 90
    d.ellipse([cx - rr, cy - rr, cx + rr, cy + rr], fill=(250, 250, 250), outline=(0, 0, 0), width=3)
    ang = math.radians(-45)
    d.line([cx, cy, cx + rr * math.cos(ang), cy + rr * math.sin(ang)], fill=(200, 0, 160), width=6)
    im.save(path)
    return im, None


CARD_PROMPT = (
    "Answer five questions about this image. Output exactly five lines, each as "
    "'N: answer' with no other text, no markdown and no extra explanation.\n"
    "1. What does the large white text say?\n"
    "2. What text follows 'small text:'?\n"
    "3. List the seven small digits in order, separated by single spaces.\n"
    "4. In the 2x2 grid of numbers, what is the bottom-left number?\n"
    "5. What colour is the middle square of the three at the top left?"
)
# (label, line number, what must appear in that line's answer)
CARD_FACTS = [
    ("large text legible", 1, "qwen vision 2026"),
    ("14px text legible", 2, "kappa-17"),
    ("11px digits in order", 3, "7 3 9 1 5 8 2"),
    ("grid position correct", 4, "5"),
    ("colour identity correct", 5, "green"),
]


# ----------------------------------------------------------------------------- client
def post(url, content, max_tokens=400):
    body = {
        "model": "probe",
        "messages": [{"role": "user", "content": content}],
        "max_tokens": max_tokens,
        "temperature": 0,
        # A thinking model spends max_tokens on reasoning first and returns empty
        # content, which looks exactly like a broken image path. Ask for the answer.
        "chat_template_kwargs": {"enable_thinking": False},
    }
    req = urllib.request.Request(
        url.rstrip("/") + "/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        r = json.load(urllib.request.urlopen(req, timeout=600))
    except urllib.error.HTTPError as exc:
        return None, exc.code, exc.read().decode("utf-8", "replace")
    m = r["choices"][0]["message"]
    text = (m.get("content") or "").strip()
    if not text and m.get("reasoning_content"):
        text = m["reasoning_content"].strip()  # keep it non-empty, but never silently
    return r, 200, text


def image_part(path, mime):
    """Send the file's bytes exactly as stored -- never re-encode through Pillow.

    Re-encoding destroys the property under test for negatives (Pillow happily turns
    a CMYK JPEG into RGB, and the engine then correctly accepts it -- a false result
    that reads like a decoder regression), and for positives it would feed the tower
    a PNG instead of exercising the server's JPEG/WebP decoders at all. It also used
    to litter fixtures/ with .probe.png artifacts. Every send is raw.
    """
    data = open(path, "rb").read()
    return {"type": "image_url", "image_url": {"url": "data:%s;base64,%s" % (mime, base64.b64encode(data).decode())}}


def norm(s):
    s = s.lower()
    s = re.sub(r"[*_`#]", "", s)
    return re.sub(r"\s+", " ", s).strip()


def answers(text):
    out = {}
    for m in re.finditer(r"(?m)^\s*(\d)\s*[:.\)]\s*(.+?)\s*$", text):
        out[int(m.group(1))] = norm(m.group(2))
    return out


# ------------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default="http://127.0.0.1:8889")
    ap.add_argument("--fixtures", default=os.path.join(HERE, "fixtures"))
    ap.add_argument("--card-out", default=os.path.join(HERE, "..", "..", "logs", "vision-card.png"))
    a = ap.parse_args()

    if not os.path.isdir(a.fixtures):
        bad("fixtures directory", a.fixtures)
        return fails
    try:
        r, code, _ = post(a.url, [{"type": "text", "text": "Reply with exactly the word READY."}], 64)
        if code != 200:
            bad("server reachable", "HTTP %s" % code)
            return fails
    except Exception as exc:
        bad("server reachable", "%s" % exc)
        return fails

    # ------------------------------------------------------- the card, with known truth
    print("\n== Ground-truth reading (answers known by construction)")
    card = os.path.abspath(a.card_out)
    try:
        os.makedirs(os.path.dirname(card), exist_ok=True)
    except OSError:
        pass
    im, err = draw_card(card)
    if err:
        # A fallback font renders digits too small for the tower, which would fail the
        # assertions for a reason unrelated to the engine. Say so instead.
        warn("card drawn with a real font", err + " -- card checks skipped")
    else:
        t0 = time.time()
        r, code, text = post(a.url, [image_part(card, "image/png"), {"type": "text", "text": CARD_PROMPT}])
        got = answers(text or "")
        for label, n, want in CARD_FACTS:
            line = got.get(n, "")
            if want in line:
                ok(label, "line %d: %s" % (n, line[:60]))
            else:
                bad(label, "line %d expected %r, got %r" % (n, want, line or "(no such line)"))
        print("  %.1fs for the card (%d facts)" % (time.time() - t0, len(CARD_FACTS)))

    # --------------------------------------------- pixels actually entered the context
    # Without this, a server that dropped the image on the floor could still pass the
    # checks above by answering from... nowhere, but the token delta makes it arithmetic.
    print("\n== Pixels in the context")
    ask = "What colour is the middle square of the three at the top left?"
    r_text, _, _ = post(a.url, [{"type": "text", "text": ask}], 32)
    pt_text = (r_text or {}).get("usage", {}).get("prompt_tokens")
    r_img, _, _ = post(a.url, [image_part(card, "image/png"), {"type": "text", "text": ask}], 32)
    pt_img = (r_img or {}).get("usage", {}).get("prompt_tokens")
    if pt_text is None or pt_img is None:
        warn("prompt token accounting", "usage missing")
    elif pt_img >= pt_text + 50:
        ok("image prompt costs more than text", "%d vs %d tokens" % (pt_img, pt_text))
    else:
        bad("image prompt costs more than text", "%d vs %d -- the image may not be reaching the model" % (pt_img, pt_text))

    # ------------------------------------------------------- real files, both decoders
    print("\n== Decoders feed the tower")
    worked = False
    for f, mime in (("photo.jpg", "image/jpeg"), ("photo.webp", "image/webp"), ("photo_lossless.webp", "image/webp")):
        p = os.path.join(a.fixtures, f)
        if not os.path.exists(p):
            bad("%s fixture exists" % f)
            continue
        _, code, text = post(a.url, [image_part(p, mime), {"type": "text", "text": "What is the single most prominent colour? One word."}], 32)
        if code != 200:
            bad("%s accepted" % f, "HTTP %s" % code)
        elif not text:
            bad("%s answered" % f, "empty content with thinking disabled")
        else:
            worked = True
            ok("%s decoded and answered" % f, text[:60])

    # ------------------------------------------------------- broken input must be refused
    # Gated on a valid image having decoded: with --vision off every request is a 400,
    # and these would "pass" for entirely the wrong reason.
    print("\n== Broken input refused")
    for f, mime, why, needle in (
        ("truncated.jpg", "image/jpeg", "no EOI marker (jpeg.zig:158)", None),
        ("cmyk.jpg", "image/jpeg", "CMYK, 4 components (jpeg.zig:157)", "cmyk"),
        ("corrupt.webp", "image/webp", "not a WebP", None),
    ):
        p = os.path.join(a.fixtures, f)
        if not os.path.exists(p):
            bad("%s fixture exists" % f)
            continue
        if not worked:
            warn("%s refused (%s)" % (f, why), "not assessed -- nothing valid decoded, so a 400 only proves vision is off")
            continue
        before = open(p, "rb").read()
        _, code, body = post(a.url, [image_part(p, mime), {"type": "text", "text": "Describe this."}], 32)
        if open(p, "rb").read() != before:  # guards against a future edit re-encoding this
            bad("%s sent unmodified" % f, "fixture bytes changed in transit")
        if code == 200:
            bad("%s refused (%s)" % (f, why), "accepted, said: " + (body or "")[:80])
        elif code != 400:
            bad("%s refused with 400 (%s)" % (f, why), "HTTP %s -- a crash or timeout is not a refusal" % code)
        elif needle and needle not in body.lower():
            bad("%s refused for the right reason" % f, 'expected %r in: %s' % (needle, body[:120]))
        else:
            ok("%s refused (%s)" % (f, why), "HTTP %s" % code)

    print("\n  %d failed, %d warned" % (fails, warns))
    return fails


if __name__ == "__main__":
    sys.exit(main())

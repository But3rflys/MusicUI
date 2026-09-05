from __future__ import annotations

import base64
import io

from musicui import config, logbook

try:
    import requests
except ImportError:
    requests = None

try:
    from PIL import Image
except ImportError:
    Image = None

_FALLBACK_COLORS = [[110, 112, 128], [70, 72, 86]]

_journal = logbook.get("cover")
_missing = logbook.Changed("cover")


def _dominant_colors(img, count: int = 3) -> list[list[int]]:
    small = img.resize((64, 64))
    quantized = small.quantize(colors=8)
    palette = quantized.getpalette() or []
    entries = sorted(quantized.getcolors() or [], reverse=True)

    colors: list[list[int]] = []
    for _, index in entries:
        chunk = palette[index * 3: index * 3 + 3]
        if len(chunk) < 3:
            continue
        r, g, b = chunk
        if max(r, g, b) < 34 or min(r, g, b) > 230:
            continue
        colors.append([r, g, b])
        if len(colors) >= count:
            break

    return colors or list(_FALLBACK_COLORS)


def _square(img):
    width, height = img.size
    side = min(width, height)
    if width != height:
        left = (width - side) // 2
        top = (height - side) // 2
        img = img.crop((left, top, left + side, top + side))

    target = min(config.COVER_SIZE, side)
    if side != target:
        img = img.resize((target, target), Image.LANCZOS)
    return img


def build(data: bytes, url: str | None = None) -> dict | None:
    if Image is None:
        _missing.say("no Pillow, covers are off")
        return None
    if not data:
        return None

    try:
        with Image.open(io.BytesIO(data)) as raw:
            img = _square(raw.convert("RGB"))
            colors = _dominant_colors(img)
            buf = io.BytesIO()
            img.save(buf, format="JPEG", quality=88, optimize=True)
            b64 = base64.b64encode(buf.getvalue()).decode("ascii")
    except Exception as exc:
        _journal.warning(f"image did not parse: {type(exc).__name__}: {exc}")
        return None

    _journal.debug(f"cover ready, {len(b64) * 3 // 4} B, colors {colors}")
    return {"url": url, "b64": b64, "colors": colors}


def fetch(url: str | None) -> dict | None:
    if requests is None:
        _missing.say("no requests, cannot download covers")
        return None
    if not url:
        return None

    try:
        response = requests.get(url, timeout=8)
        response.raise_for_status()
        data = response.content
    except Exception as exc:
        _journal.warning(f"download failed: {type(exc).__name__}: {exc}")
        return None

    return build(data, url)
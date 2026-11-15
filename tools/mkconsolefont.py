#!/usr/bin/env python3
"""Build a readable PSF2 bitmap font and a kbd Unicode table.

WenQuanYi Zen Hei is a build-only source dependency. ASCII and the UI's CJK
characters are rasterized into a 256-glyph font. kbd's psfaddtable attaches
the Unicode map and psfgettable verifies it; the TTF/TTC is not shipped.
"""
from __future__ import annotations

import argparse
import struct
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

PSF2_MAGIC = 0x864AB572
FONT_WIDTH = 18
FONT_HEIGHT = 20
FONT_SIZE = 17
GLYPH_COUNT = 256


def is_ui_unicode(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x3400 <= cp <= 0x4DBF
        or 0x4E00 <= cp <= 0x9FFF
        or 0x3000 <= cp <= 0x303F
        or 0xFF00 <= cp <= 0xFFEF
        or 0x2000 <= cp <= 0x206F
    )


def render_glyph(ch: str, font: ImageFont.FreeTypeFont) -> bytes:
    image = Image.new("L", (FONT_WIDTH, FONT_HEIGHT), 0)
    draw = ImageDraw.Draw(image)
    if ch != " ":
        draw.text(
            (FONT_WIDTH // 2, FONT_HEIGHT // 2), ch, font=font,
            fill=255, anchor="mm", stroke_width=0
        )
    pixels = image.load()
    row_bytes = (FONT_WIDTH + 7) // 8
    result = bytearray()
    for y in range(FONT_HEIGHT):
        for byte_x in range(row_bytes):
            value = 0
            for bit in range(8):
                x = byte_x * 8 + bit
                if x < FONT_WIDTH and pixels[x, y] >= 96:
                    value |= 0x80 >> bit
            result.append(value)
    return bytes(result)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--font", required=True)
    parser.add_argument("--output", required=True, help="PSF2 bitmap-only font")
    parser.add_argument("--table-output", required=True, help="kbd psfaddtable input")
    parser.add_argument("--source", action="append", default=[])
    args = parser.parse_args()

    source_chars: set[str] = set()
    for source in args.source:
        source_chars.update(
            ch for ch in Path(source).read_text(encoding="utf-8")
            if is_ui_unicode(ch)
        )

    ascii_chars = [chr(cp) for cp in range(32, 127)]
    selected = set(source_chars)
    if len(ascii_chars) + len(selected) > GLYPH_COUNT:
        raise SystemExit(
            f"UI requires {len(ascii_chars) + len(source_chars)} glyphs; "
            f"256-glyph console font limit is {GLYPH_COUNT}"
        )

    chars = ascii_chars + sorted(selected)
    if len(chars) > GLYPH_COUNT:
        raise SystemExit(f"selected {len(chars)} glyphs; limit is {GLYPH_COUNT}")

    font = ImageFont.truetype(args.font, FONT_SIZE, index=0)
    glyph_data = bytearray()
    for index in range(GLYPH_COUNT):
        ch = chars[index] if index < len(chars) else None
        glyph_data.extend(render_glyph(ch or " ", font))

    row_bytes = (FONT_WIDTH + 7) // 8
    char_size = FONT_HEIGHT * row_bytes
    header = struct.pack(
        "<8I", PSF2_MAGIC, 0, 32, 0, GLYPH_COUNT,
        char_size, FONT_HEIGHT, FONT_WIDTH
    )
    output = Path(args.output)
    table_output = Path(args.table_output)
    output.parent.mkdir(parents=True, exist_ok=True)
    table_output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(header + glyph_data)
    with table_output.open("w", encoding="ascii", newline="\n") as table:
        for index, ch in enumerate(chars):
            table.write(f"{index} U+{ord(ch):04X}\n")

    print(
        f"Created {output}: {FONT_WIDTH}x{FONT_HEIGHT}, {GLYPH_COUNT} glyph slots, "
        f"{len(source_chars)} UI CJK characters; kbd Unicode table: {table_output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

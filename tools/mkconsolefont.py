#!/usr/bin/env python3
"""Build a readable PSF2 console font with ASCII at its native code positions.

Linux consoles can fall back to direct 8-bit glyph indexing when a Unicode
mapping is unavailable or reset. Therefore ASCII U+0020..U+007E is stored at
the identically numbered glyph slots, while CJK characters use otherwise
unused control/DEL/high-byte slots. psfaddtable adds the UTF-8 Unicode map for
the CJK glyphs. The WQY source font remains build-only.
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
ASCII_FIRST = 32
ASCII_LAST = 126
CJK_SLOTS = tuple(range(0, 32)) + tuple(range(127, GLYPH_COUNT))


def is_ui_unicode(ch: str) -> bool:
    cp = ord(ch)
    return (
        0x3400 <= cp <= 0x4DBF
        or 0x4E00 <= cp <= 0x9FFF
        or 0x3000 <= cp <= 0x303F
        or 0xFF00 <= cp <= 0xFFEF
        or 0x2000 <= cp <= 0x206F
    )


def render_glyph(ch: str | None, font: ImageFont.FreeTypeFont) -> bytes:
    image = Image.new("L", (FONT_WIDTH, FONT_HEIGHT), 0)
    draw = ImageDraw.Draw(image)
    if ch is not None and ch != " ":
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
    source_chars.difference_update(chr(cp) for cp in range(ASCII_FIRST, ASCII_LAST + 1))
    if len(source_chars) > len(CJK_SLOTS):
        raise SystemExit(
            f"UI requires {len(source_chars)} CJK glyphs; only "
            f"{len(CJK_SLOTS)} safe slots remain after preserving ASCII positions"
        )

    slot_chars: list[str | None] = [None] * GLYPH_COUNT
    for cp in range(ASCII_FIRST, ASCII_LAST + 1):
        slot_chars[cp] = chr(cp)
    cjk_slots = CJK_SLOTS[:len(source_chars)]
    for slot, ch in zip(cjk_slots, sorted(source_chars)):
        slot_chars[slot] = ch

    font = ImageFont.truetype(args.font, FONT_SIZE, index=0)
    glyph_data = bytearray()
    for ch in slot_chars:
        glyph_data.extend(render_glyph(ch, font))

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
        for slot, ch in enumerate(slot_chars):
            if ch is not None:
                table.write(f"{slot} U+{ord(ch):04X}\n")

    print(
        f"Created {output}: {FONT_WIDTH}x{FONT_HEIGHT}, {GLYPH_COUNT} glyph slots, "
        f"{ASCII_LAST - ASCII_FIRST + 1} native-position ASCII glyphs, "
        f"{len(source_chars)} CJK glyphs"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

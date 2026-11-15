#!/usr/bin/env python3
"""Build a readable PSF2 bitmap font and a kbd Unicode table.

WenQuanYi Zen Hei is a build-only source dependency. ASCII and the UI's CJK
characters are rasterized into a 512-glyph font. kbd's psfaddtable attaches
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
GLYPH_COUNT = 512

COMMON_CHINESE = (
    "的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题党程展五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接知较将组见计别她手角期根论运农指几九区强放决西被干做必战先回则任取据处理世车白教速花带安场身车例真务具万每目至达走积示议声报完金类离华名确才科张信马节话米整空元况今集温传土许步群广石记需段研界拉林律叫且究观越织装影算低持音众书布复容儿须际商非验连断深难近矿千周委素技备半办青省列习响约支般史感劳便团往酸历市克何除消构府称太准精值号率族维划选标写存候毛亲快效斯院查江型眼王按格养易置派层片始却专状育厂京识适属圆包火住调满县局照参红细引听该铁价严龙飞"
)
EXTRA_PUNCTUATION = "　、。，．！？：；（）［］【】「」『』《》〈〉…·—－＋－×÷＝％＃＆＊＠￥＄€°℃→←↑↓✓✗"


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
    selected.update(EXTRA_PUNCTUATION)
    for ch in COMMON_CHINESE:
        if len(ascii_chars) + len(selected) >= GLYPH_COUNT:
            break
        selected.add(ch)

    if len(ascii_chars) + len(source_chars) > GLYPH_COUNT:
        raise SystemExit(
            f"UI requires {len(ascii_chars) + len(source_chars)} glyphs; "
            f"console font limit is {GLYPH_COUNT}"
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
            table.write(f"{index} 0x{ord(ch):04X}\n")

    print(
        f"Created {output}: {FONT_WIDTH}x{FONT_HEIGHT}, {GLYPH_COUNT} glyph slots, "
        f"{len(source_chars)} UI CJK characters; kbd Unicode table: {table_output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

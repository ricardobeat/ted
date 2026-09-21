#!/usr/bin/env -S uv run --quiet
# /// script
# requires-python = ">=3.9"
# dependencies = ["fonttools"]
# ///
"""Build ted's GUI font: JetBrains Mono plus the symbols it lacks.

JetBrains Mono carries no braille and only part of the geometric-shape,
check-mark and arrow blocks, so a view that draws its own rules, list markers
and spinners comes out full of holes. This merges those glyphs in from a
standard system monospace font (SF Mono) and writes the result into
assets/fonts, next to the sources it reads. Nothing is installed: the app
loads the output itself.

Both faces advance 0.6 em, so the merged glyphs land on the same grid as the
text, which is what lets gui_main.c3 pin a cell width to the point size.

Derived fonts cannot keep the upstream name: JetBrains Mono is a reserved
name under the SIL Open Font License, so the output is renamed.

    uv run tools/make_font.py                       # JetBrains + SF Mono
    uv run tools/make_font.py --primary <path> --name "Ted Mono" --out <path>
"""
import argparse
import os
import sys
import tempfile

from fontTools import subset
from fontTools.merge import Merger
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTFont
from fontTools.ttLib.scaleUpem import scale_upem

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FONTS = os.path.join(ROOT, "assets", "fonts")
DEFAULT_PRIMARY = os.path.join(FONTS, "source", "JetBrainsMono-Regular.ttf")
DEFAULT_SYMBOLS = "/System/Library/Fonts/SFNSMono.ttf"

# Ranges the view draws but iA Writer has no glyphs for: arrows, general
# punctuation, box drawing, block elements, geometric shapes, check marks and
# braille. Braille is absent from SF Mono too; it is listed so a font that
# does carry it keeps it.
SYMBOL_RANGES = [
    (0x0020, 0x0020),  # space
    (0x2190, 0x21BB),  # arrows
    (0x2217, 0x2219),
    (0x2248, 0x2248),
    (0x2500, 0x257F),  # box drawing
    (0x2580, 0x259F),  # block elements
    (0x25A0, 0x25FF),  # geometric shapes, including the list markers
    (0x2713, 0x2727),  # check marks and sparkles
    (0x2807, 0x283C),  # braille (boba's spinner frames)
]


def unicodes():
    out = []
    for lo, hi in SYMBOL_RANGES:
        out.extend(range(lo, hi + 1))
    return out


def symbol_source(path, upem, out_path):
    """Write the system font, reduced to the symbol ranges, to out_path."""
    opts = subset.Options()
    opts.glyph_names = True
    opts.name_IDs = ["*"]
    opts.name_legacy = True
    font = subset.load_font(path, opts)
    subsetter = subset.Subsetter(options=opts)
    subsetter.populate(unicodes=unicodes())
    subsetter.subset(font)
    # Merging needs one em size: scale the system font's 2048-unit em down to
    # the iA Writer/Plex 1000-unit em.
    if font["head"].unitsPerEm != upem:
        scale_upem(font, upem)
    subset.save_font(font, out_path, opts)
    return out_path


def rename(font, family):
    for name_id, value in ((1, family), (4, family), (6, family.replace(" ", "")),
                           (16, family), (17, "Regular")):
        font["name"].setName(value, name_id, 3, 1, 0x409)
    font["name"].setName("Version 1.000", 5, 3, 1, 0x409)


def clamp_heights(font, max_span):
    """Clip each glyph's ink to at most max_span font units, keeping its own
    vertical centre. The symbol fonts draw box rules a full 1.37 em tall, so
    their rasterised boxes exceed the requested point size and raylib warns on
    every one of them; at the app's cell pitch the rules are dashed anyway, so
    the trimmed ink costs nothing visually."""
    glyf = font["glyf"]
    glyph_set = font.getGlyphSet()

    def pen_for(pen, lo, hi):
        class Clamp:
            def moveTo(self, p):
                pen.moveTo((p[0], min(max(p[1], lo), hi)))

            def lineTo(self, p):
                pen.lineTo((p[0], min(max(p[1], lo), hi)))

            def qCurveTo(self, *pts):
                pen.qCurveTo(*[(x, min(max(y, lo), hi)) for x, y in pts])

            def cCurveTo(self, *pts):
                pen.cCurveTo(*[(x, min(max(y, lo), hi)) for x, y in pts])

            def addComponent(self, glyph_name, transform, identifier=None):
                pen.addComponent(glyph_name, transform, identifier)

            def closePath(self):
                pen.closePath()

            def endPath(self):
                pen.endPath()
        return Clamp()

    for name in font.getGlyphOrder():
        g = glyph_set[name]
        bp = BoundsPen(glyph_set)
        g.draw(bp)
        bb = bp.bounds
        if bb is None:
            continue
        span = bb[3] - bb[1]
        if span <= max_span:
            continue
        centre = (bb[1] + bb[3]) / 2.0
        lo, hi = centre - max_span / 2.0, centre + max_span / 2.0
        out_pen = TTGlyphPen(glyph_set)
        clamp = pen_for(out_pen, lo, hi)
        g.draw(clamp)
        glyf[name] = out_pen.glyph()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--primary", default=DEFAULT_PRIMARY)
    ap.add_argument("--symbols", default=DEFAULT_SYMBOLS)
    ap.add_argument("--name", default="Ted Mono")
    ap.add_argument("--out", default=os.path.join(FONTS, "TedMono-Regular.ttf"))
    args = ap.parse_args()

    for path in (args.primary, args.symbols):
        if not os.path.exists(path):
            print(f"missing font: {path}", file=sys.stderr)
            return 1

    target_upem = TTFont(args.primary)["head"].unitsPerEm
    with tempfile.TemporaryDirectory() as tmp:
        symbols_path = symbol_source(args.symbols, target_upem,
                                     os.path.join(tmp, "symbols.ttf"))
        # The merger opens the files itself, so the subsetted symbol font has
        # to go through disk. First font wins where both carry a codepoint, so
        # iA Writer's own letters and metrics are the ones that survive.
        merged = Merger().merge([args.primary, symbols_path])
    # raylib warns when a glyph's rasterised height exceeds the requested
    # point size, and the box rules from the symbol fonts are drawn too tall.
    # the primary line box is 1320 units (hhea 1020/-300), and 1300 is the
    # tallest clamp raylib rasterises without warning at the atlas sizes this
    # app uses: it leaves the ~1.5% of headroom raylib's rounding wants, and
    # still runs a box rule the full height of the row, so vertical rules
    # meet across rows instead of dashing.
    clamp_heights(merged, 1300)
    rename(merged, args.name)
    merged.save(args.out)
    print(f"{args.name}: {args.out} ({os.path.getsize(args.out)} bytes)")

    check = TTFont(args.out).getBestCmap()
    wanted = [("i", 0x69), ("m", 0x6d), ("-", 0x2d), ("|", 0x7c),
              ("box 2500", 0x2500), ("box 2502", 0x2502), ("blk 2588", 0x2588),
              ("tri 25b8", 0x25b8), ("arrow 2190", 0x2190), ("check 2713", 0x2713)]
    missing = [label for label, cp in wanted if cp not in check]
    print("coverage:", "complete" if not missing else f"missing {missing}")
    return 0


if __name__ == "__main__":
    sys.exit(main())

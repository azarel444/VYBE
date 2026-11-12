#!/usr/bin/env python3
"""Extend the original VYBE Riot TTF using the hand-traced Illustrator SVG.
Do not edit the original A-Z outlines. Run after side-bearing normalization.
"""
from pathlib import Path
from statistics import median
from lxml import etree
from fontTools.ttLib import TTFont
from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.pens.cu2quPen import Cu2QuPen
from fontTools.pens.transformPen import TransformPen
from fontTools.svgLib.path import parse_path

ROOT = Path(__file__).resolve().parents[1]
FONT = ROOT / 'assets/fonts/VYBE_Riot.ttf'
SVG = ROOT / 'assets/fonts/VYBE_Riot_Extra_Glyphs.svg'
svg = etree.parse(str(SVG)).getroot()
parts = list(svg)
font = TTFont(FONT)
glyf = font['glyf']
upem = font['head'].unitsPerEm
cmap = font.getBestCmap()

# Illustrator occasionally grouped *two* separate characters together.
# These three groups are divided on their physical midpoints; the separate
# accent for the second E (top-level #84) is explicitly attached to it.
row0_ids = [0,28,3,8,6,4,5,15,1,7,70,66,68,72,67,71,69,35,37,29,30,26,23]
row0_chars = list("0123456789.,'`\"!?()[]{}")
row1_ids = [9,10,16,62,65,12,53,44,61,59,52,56,118,119,120,121,50,60,64,31,51,77]
row1_chars = list("@#$%^&*+=-_~/\\|¦<>≤≥×÷")
row2_ids = [24,17,14,19,11,18,2,122,22,55,63,54,57,25,13,49,38,78,73,58]
row2_chars = list("¢£€¥₽₹₩©®™°ªº§¶†‡…·•")
row3_elements = [
    [(39,None)],[(47,None)],[(41,None)],[(113,None)],[(42,None)],
    [(97,None)],[(101,535,'left')],[(101,535,'right')],
    [(21,None)],[(45,None)],[(106,None)],[(107,None)],
    [(81,1000,'left')],[(81,1000,'right')],[(40,None)],
    [(110,None)],[(108,None)],[(79,None)],[(114,None)],
    [(96,1475,'left')],[(96,1475,'right'),(84,None)],
    [(100,None)],[(43,None)],[(99,None)],[(95,None)],[(75,None)],
    [(80,None)],[(88,None)],[(89,None)]
]
row3_chars = list("ÁÀÂÄÃÅĀĂÆÇĆĈČÐĐÈÉÊËĒĚĖĘÌÍÎĪĮÑ")
row4_ids = [98,103,76,112,91,82,87,27,20,34,32,111,90,93,46,33,102,105,85,116,94,86,74,104,83,115,92,109,36,48]
row4_chars = list("ÓÒÔÖŌÕŐØŒŘŔŚŜŠÞßÚÙÛÜŪŨŮÝŶŸŽŻŹŁ")
assert all(len(a)==len(b) for a,b in [
    (row0_ids,row0_chars),(row1_ids,row1_chars),
    (row2_ids,row2_chars),(row3_elements,row3_chars),
    (row4_ids,row4_chars)
]), "Character-sheet mapping length mismatch"

# Preserve the visible A-Z baseline and cap height from the established font.
a_name = cmap.get(ord('A'))
if a_name is None:
    raise RuntimeError('Base Riot font missing A glyph')
a = glyf[a_name]
a.recalcBounds(glyf)
cap_height = a.yMax - a.yMin
cap_bottom = a.yMin
# The hand-traced extended caps have body heights of roughly 54 SVG units;
# their accents extend above that cap, rather than shrinking the letter.
scale_caps = cap_height / 54.0
# Keep the established punctuation/symbol sizes. The traced numeral source
# has visibly unequal outlines (notably 5 versus 2), so digits will instead
# receive the SAME cap height as a typical A-Z letter.
scale_other = cap_height / 104.0
normal_caps = []
for letter in 'ABCDEFGHIJKLMNOPQRSTUVWXYZ':
    cap_name = cmap.get(ord(letter))
    if cap_name is None:
        continue
    cap_glyph = glyf[cap_name]
    cap_glyph.recalcBounds(glyf)
    normal_caps.append(cap_glyph)
if len(normal_caps) != 26:
    raise RuntimeError('Riot A-Z metrics are required for consistent digits')
digit_height = median(g.yMax - g.yMin for g in normal_caps)
digit_bottom = median(g.yMin for g in normal_caps)

def path_bounds(el):
    p=BoundsPen(None)
    tag=etree.QName(el).localname
    if tag=='path':
        parse_path(el.get('d'),p)
    elif tag=='polygon':
        pts=[float(x) for x in el.get('points').replace(',',' ').split()]
        if pts:
            p.moveTo((pts[0],pts[1]))
            for i in range(2,len(pts),2):p.lineTo((pts[i],pts[i+1]))
            p.closePath()
    return p.bounds

def select_shapes(spec):
    shapes=[]
    for term in spec:
        idx=term[0]
        boundary=term[1] if len(term)>1 else None
        side=term[2] if len(term)>2 else None
        for el in parts[idx].iter():
            if etree.QName(el).localname not in ('path','polygon'):
                continue
            b=path_bounds(el)
            if b is None: continue
            if boundary is not None:
                midpoint=(b[0]+b[2])/2
                if side=='left' and midpoint >= boundary: continue
                if side=='right' and midpoint < boundary: continue
            shapes.append((el,b))
    return shapes

def make_glyph(char,spec,cap_row):
    shapes=select_shapes(spec)
    if not shapes:
        raise RuntimeError('No outlines for %r' % char)
    xmin=min(b[0] for _,b in shapes)
    xmax=max(b[2] for _,b in shapes)
    ymin=min(b[1] for _,b in shapes)
    ymax=max(b[3] for _,b in shapes)
    is_digit = cap_row == 0 and char in '0123456789'
    # Equalize all ten visible numeral bounds to the median normal Riot
    # uppercase cap height, not the unusually tall A or the arbitrary
    # source-row height. Preserve each numeral's aspect ratio.
    scale = (digit_height / max(1.0, ymax - ymin) if is_digit else
        (scale_caps if cap_row else scale_other))
    # Preserve the existing accented-letter and punctuation baselines.
    row_bottom=543 if cap_row==3 else (647 if cap_row==4 else
        (118 if cap_row==0 else (260 if cap_row==1 else 407)))
    dx=8-xmin*scale
    # For numerals, a common optical baseline makes 5 and 2 the same
    # height on screen. Alphabetic outlines remain untouched.
    dy=(digit_bottom+ymax*scale) if is_digit else (cap_bottom+row_bottom*scale)
    pen=TTGlyphPen(None)
    # Every SVG cubic becomes quadratic to form a valid TrueType glyf outline.
    quad=Cu2QuPen(pen,max_err=1.0,reverse_direction=False)
    transformed=TransformPen(quad,(scale,0,0,-scale,dx,dy))
    for el,_ in shapes:
        tag=etree.QName(el).localname
        if tag=='path':
            parse_path(el.get('d'),transformed)
        else:
            pts=[float(x) for x in el.get('points').replace(',',' ').split()]
            transformed.moveTo((pts[0],pts[1]))
            for i in range(2,len(pts),2):transformed.lineTo((pts[i],pts[i+1]))
            transformed.closePath()
    name='riotExtra%04X' % ord(char)
    advance=max(30,round((xmax-xmin)*scale+16))
    return name,pen.glyph(),(advance,8)

new_order=list(font.getGlyphOrder())
rows = [
    (row0_chars,[[(i,None)] for i in row0_ids],0),
    (row1_chars,[[(i,None)] for i in row1_ids],1),
    (row2_chars,[[(i,None)] for i in row2_ids],2),
    (row3_chars,row3_elements,3),
    (row4_chars,[[(i,None)] for i in row4_ids],4)
]
generated={}
for chars,specs,row in rows:
    for char,spec in zip(chars,specs):
        name,glyph,metrics=make_glyph(char,spec,row)
        if name not in new_order:
            new_order.append(name)
        glyf[name]=glyph
        font['hmtx'].metrics[name]=metrics
        generated[ord(char)]=name

font.setGlyphOrder(new_order)
font['maxp'].numGlyphs=len(new_order)
font['hhea'].numberOfHMetrics=len(new_order)
for table in font['cmap'].tables:
    if table.isUnicode():
        table.cmap.update({cp:name for cp,name in generated.items() if cp<=0xFFFF or table.format in (12,13)})
font.save(FONT)
print('VYBE Riot: added/replaced %d Unicode glyphs, font now %d glyphs (%d bytes)' %
      (len(generated),len(new_order),FONT.stat().st_size))
check_font = TTFont(FONT)
check_cmap = check_font.getBestCmap()
assert ord('Á') in check_cmap
digit_bounds = []
for char in '0123456789':
    glyph = check_font['glyf'][check_cmap[ord(char)]]
    glyph.recalcBounds(check_font['glyf'])
    digit_bounds.append(glyph.yMax - glyph.yMin)
assert max(digit_bounds) - min(digit_bounds) <= 3, (
    'Riot digits must have uniform visible heights: %r' % digit_bounds)

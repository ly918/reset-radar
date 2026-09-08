#!/usr/bin/env python3
"""Generate original vector branding and the macOS icon (requires Pillow + iconutil)."""
from pathlib import Path
from PIL import Image, ImageDraw
import math, subprocess, tempfile
ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/brand'
OUT.mkdir(parents=True, exist_ok=True)
N = 2048
S = N / 1024

def box(v): return tuple(round(x * S) for x in v)
def points(v): return [(round(x*S), round(y*S)) for x,y in v]
def circle(draw, x, y, r, fill): draw.ellipse(box((x-r,y-r,x+r,y+r)), fill=fill)
def gradient(top, bottom):
    im = Image.new('RGBA', (N,N))
    d = ImageDraw.Draw(im)
    for y in range(N):
        t=y/(N-1)
        d.line((0,y,N,y), fill=tuple(round(a+(b-a)*t) for a,b in zip(top,bottom))+(255,))
    return im

canvas = Image.new('RGBA', (N,N))
mask = Image.new('L',(N,N)); d=ImageDraw.Draw(mask)
d.rounded_rectangle(box((64,64,960,960)), radius=round(208*S), fill=255)
canvas.paste(gradient((53,56,61),(22,25,29)),(0,0),mask)
d=ImageDraw.Draw(canvas)
d.rounded_rectangle(box((65,65,959,959)), radius=round(207*S), outline=(255,255,255,30), width=round(2*S))
# A tactile RESET key: shallow gold face, darker front edge, reset symbol.
d.rounded_rectangle(box((186,282,838,792)), radius=round(94*S), fill=(0,0,0,80))
d.rounded_rectangle(box((192,260,832,766)), radius=round(86*S), fill=(117,78,24,255))
face=Image.new('L',(N,N)); fd=ImageDraw.Draw(face)
fd.rounded_rectangle(box((192,224,832,702)),radius=round(86*S),fill=255)
canvas.alpha_composite(Image.composite(gradient((255,236,189),(183,137,54)),Image.new('RGBA',(N,N)),face))
d=ImageDraw.Draw(canvas)
d.rounded_rectangle(box((194,226,830,700)),radius=round(84*S),outline=(255,245,209,120),width=round(3*S))
ink=(55,43,25,255)
d.arc(box((433,303,591,461)),start=40,end=315,fill=ink,width=round(17*S))
d.polygon(points([(592,365),(550,352),(583,323)]),fill=ink)
# Custom vector lettering rather than a bundled font.
letters={
 'R': [[(0,84),(0,0),(43,0),(60,14),(60,29),(44,43),(0,43)],[(33,43),(64,84)]],
 'E': [[(60,0),(0,0),(0,84),(60,84)],[(0,42),(49,42)]],
 'S': [[(60,0),(15,0),(0,15),(0,28),(15,42),(45,42),(60,56),(60,69),(45,84),(0,84)]],
 'T': [[(0,0),(64,0)],[(32,0),(32,84)]]}
letter_paths=[]
for index,char in enumerate('RESET'):
    for path in letters[char]:
        coords=[(x+296+index*92,y+520) for x,y in path]
        d.line(points(coords),fill=ink,width=round(14*S),joint='curve')
        for x,y in coords: circle(d,x,y,7,ink)
        letter_paths.append('M'+' L'.join(f'{x} {y}' for x,y in coords))
canvas=canvas.resize((1024,1024),Image.Resampling.LANCZOS)
canvas.save(OUT/'logo.png')
# Editable SVG uses the same geometry and lettering.
svg = '''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024" role="img" aria-label="Reset Radar: a gold RESET button">
<defs>
  <linearGradient id="tile" x2="0" y2="1"><stop stop-color="#35383d"/><stop offset="1" stop-color="#16191d"/></linearGradient>
  <linearGradient id="key" x2="0" y2="1"><stop stop-color="#f1d89d"/><stop offset="1" stop-color="#d0ab68"/></linearGradient>
</defs>
<rect x="64" y="64" width="896" height="896" rx="208" fill="url(#tile)"/>
<rect x="65" y="65" width="894" height="894" rx="207" fill="none" stroke="#fff" stroke-opacity=".12" stroke-width="2"/>
<rect x="186" y="282" width="652" height="510" rx="94" fill="#000" fill-opacity=".31"/>
<rect x="192" y="260" width="640" height="506" rx="86" fill="#754e18"/>
<rect x="192" y="224" width="640" height="478" rx="86" fill="url(#key)"/>
<rect x="194" y="226" width="636" height="474" rx="84" fill="none" stroke="#fff5d1" stroke-opacity=".47" stroke-width="3"/>
<path d="M566 427 A70.5 70.5 0 1 1 562 332" fill="none" stroke="#372b19" stroke-width="17"/>
<path d="M592 365L550 352L583 323Z" fill="#372b19"/>
'''
svg += ''.join(f'<path d="{p}" fill="none" stroke="#372b19" stroke-width="14" stroke-linecap="round" stroke-linejoin="round"/>\n' for p in letter_paths)
(OUT/'logo.svg').write_text(svg+'</svg>\n')
with tempfile.TemporaryDirectory(prefix='reset-radar-icon-') as tmp:
    iconset=Path(tmp)/'AppIcon.iconset'; iconset.mkdir()
    for size in [16,32,128,256,512]:
        for scale in [1,2]:
            suffix='@2x' if scale==2 else ''
            canvas.resize((size*scale,size*scale),Image.Resampling.LANCZOS).save(iconset/f'icon_{size}x{size}{suffix}.png')
    subprocess.run(['iconutil','-c','icns',str(iconset),'-o',str(ROOT/'apps/macos/Resources/AppIcon.icns')],check=True)
print('Generated docs/brand/logo.svg, logo.png and apps/macos/Resources/AppIcon.icns')

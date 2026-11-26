import math, pathlib

BG = "#0A4F45"      # deep green
CREAM = "#FBFAF7"   # the letter H
ORANGE = "#FF7A3D"  # pointer, waves, destination dot

# H geometry on a 1024 canvas (kept inside the adaptive-icon safe zone)
L, R, T, B = 312, 712, 292, 732      # outer box
STEM = 90
BAR_T, BAR_B = 472, 552              # crossbar
pin_cx, pin_cy = 462, 628            # pin head centre (lower-left pocket)
dest = (574, 366)                    # destination (upper-right pocket)

def arc(cx, cy, r, a0, a1):
    """Arc from angle a0 to a1 (degrees, counter-clockwise from +x, y up)."""
    x0 = cx + r * math.cos(math.radians(a0)); y0 = cy - r * math.sin(math.radians(a0))
    x1 = cx + r * math.cos(math.radians(a1)); y1 = cy - r * math.sin(math.radians(a1))
    # a0 > a1 means we sweep clockwise on screen
    return f"M {x0:.1f} {y0:.1f} A {r} {r} 0 0 1 {x1:.1f} {y1:.1f}"

# direction from pin to destination
ang = math.degrees(math.atan2(pin_cy - dest[1], dest[0] - pin_cx))
radii = [84, 132, 180]
span = 22
arcs = [arc(pin_cx, pin_cy, r, ang + span, ang - span) for r in radii]

# dotted trail from the last wave to the destination
dots = []
for r in (212, 234):
    dots.append((pin_cx + r * math.cos(math.radians(ang)), pin_cy - r * math.sin(math.radians(ang))))

def glyph():
    h = f'''
  <rect x="{L}" y="{T}" width="{STEM}" height="{B-T}" rx="14" fill="{CREAM}"/>
  <rect x="{R-STEM}" y="{T}" width="{STEM}" height="{B-T}" rx="14" fill="{CREAM}"/>
  <rect x="{L+STEM-6}" y="{BAR_T}" width="{R-L-2*STEM+12}" height="{BAR_B-BAR_T}" fill="{CREAM}"/>
'''
    # waves: dark outline first so they stay readable over the crossbar
    for a in arcs:
        h += f'  <path d="{a}" fill="none" stroke="{BG}" stroke-width="32" stroke-linecap="round"/>\n'
    for a in arcs:
        h += f'  <path d="{a}" fill="none" stroke="{ORANGE}" stroke-width="18" stroke-linecap="round"/>\n'
    for (x, y) in dots:
        h += f'  <circle cx="{x:.1f}" cy="{y:.1f}" r="9" fill="{ORANGE}"/>\n'
    # pointer: map pin, head centre (pin_cx, pin_cy), tip below
    r = 34
    tip = pin_cy + 78
    h += f'''  <path d="M {pin_cx} {tip} C {pin_cx-18} {tip-26} {pin_cx-r} {pin_cy+12} {pin_cx-r} {pin_cy} A {r} {r} 0 1 1 {pin_cx+r} {pin_cy} C {pin_cx+r} {pin_cy+12} {pin_cx+18} {tip-26} {pin_cx} {tip} Z" fill="{ORANGE}"/>
  <circle cx="{pin_cx}" cy="{pin_cy}" r="13" fill="{BG}"/>
'''
    # destination: ring + dot
    h += f'''  <circle cx="{dest[0]}" cy="{dest[1]}" r="30" fill="none" stroke="{CREAM}" stroke-width="13"/>
  <circle cx="{dest[0]}" cy="{dest[1]}" r="11" fill="{ORANGE}"/>
'''
    return h

def svg(background, scale):
    bg = f'<rect width="1024" height="1024" fill="{BG}"/>' if background else ''
    t = f'translate(512 512) scale({scale}) translate(-512 -512)'
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
  {bg}
  <g transform="{t}">
{glyph()}  </g>
</svg>
'''

out = pathlib.Path('.')
(out / 'icon_foreground.svg').write_text(svg(False, 1.1))       # adaptive foreground (transparent)
(out / 'icon_full.svg').write_text(svg(True, 1.28))              # full square icon (legacy + store)
print('pin->dest angle', round(ang, 1))

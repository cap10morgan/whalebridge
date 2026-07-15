#!/usr/bin/env python3
"""Generate the menu bar glyph and its "starting up" animation frames.

The glyph is a whale tail whose flukes double as a suspension bridge's towers.
To animate it we lift the tail while the deck stays put, so displacement is
scaled by a weight that falls to zero at the roadway: the flukes rise a full
1.6px, the stem stretches, and the cables stay attached to both ends.
"""
import math
import pathlib

ASSETS = pathlib.Path(__file__).resolve().parent.parent / "assets"

DECK_Y = 15.18
DECK_X0, DECK_X1 = 0.5, 17.5
# Above this the glyph moves as a rigid body; below it tapers into the deck.
RIGID_ABOVE_Y = 11.0
FRAMES = 12
AMPLITUDE = 1.6

TAIL = [
    (10.72, 15.18), (7.24, 15.16), (7.51, 14.53), (7.61, 13.48), (7.61, 12.12),
    (7.36, 11.18), (6.85, 10.63), (6.23, 10.26), (4.08, 9.53), (3.08, 9.06),
    (1.97, 8.09), (1.28, 7.15), (0.71, 5.80), (0.50, 4.59), (0.52, 3.62),
    (1.83, 4.67), (2.77, 5.08), (3.92, 5.29), (6.07, 5.39), (7.07, 5.72),
    (8.43, 6.66), (9.00, 7.44), (9.63, 6.60), (10.93, 5.72), (11.93, 5.39),
    (14.08, 5.29), (15.39, 5.04), (16.17, 4.67), (17.50, 3.65), (17.50, 4.53),
    (17.29, 5.80), (16.72, 7.15), (16.03, 8.09), (14.92, 9.06), (13.92, 9.53),
    (11.87, 10.21), (11.15, 10.63), (10.64, 11.18), (10.39, 12.12),
    (10.39, 13.54), (10.49, 14.58), (10.76, 15.16),
]

# Anchor cables: start on the fluke's outer edge, curve out to the deck ends.
CABLES = [
    ((2.10, 7.80), (2.10, 10.40), (1.70, 13.30), (0.75, DECK_Y)),
    ((15.90, 7.80), (15.90, 10.40), (16.30, 13.30), (17.25, DECK_Y)),
]
# Vertical suspenders: (x, y at the tail's underside).
SUSPENDERS = [(4.30, 9.20), (6.30, 9.90), (11.70, 9.91), (13.70, 9.20)]


def lift(point, dy):
    """Displace a point by dy, tapering to zero where it meets the roadway."""
    x, y = point
    weight = min(max((DECK_Y - y) / (DECK_Y - RIGID_ABOVE_Y), 0.0), 1.0)
    return x, y + dy * weight


def fmt(point):
    return f"{point[0]:.2f} {point[1]:.2f}"


def svg(dy):
    tail = [lift(p, dy) for p in TAIL]
    tail_d = "M " + " L ".join(fmt(p) for p in tail) + " Z"

    cables = []
    for start, c1, c2, end in CABLES:
        s, a, b, e = (lift(p, dy) for p in (start, c1, c2, end))
        cables.append(f'      <path d="M {fmt(s)} C {fmt(a)}, {fmt(b)}, {fmt(e)}"/>')

    suspenders = []
    for x, top in SUSPENDERS:
        _, y = lift((x, top), dy)
        suspenders.append(f'      <path d="M {x:.2f} {y:.2f} V {DECK_Y:.2f}"/>')

    return f"""<svg width="18" height="18" viewBox="0 0 18 18" xmlns="http://www.w3.org/2000/svg">
  <g stroke="black" stroke-linecap="round">
    <g stroke-width="1.1" fill="none">
{chr(10).join(cables)}
    </g>
    <g stroke-width="0.8" fill="none">
{chr(10).join(suspenders)}
    </g>
    <path d="M {DECK_X0} {DECK_Y} H {DECK_X1}" stroke-width="1.5" fill="none"/>
    <path fill="black" stroke-width="0.4" stroke-linejoin="round" d="{tail_d}"/>
  </g>
</svg>
"""


def main():
    (ASSETS / "menubar.svg").write_text(svg(0.0))
    frames = ASSETS / "menubar-frames"
    frames.mkdir(exist_ok=True)
    for i in range(FRAMES):
        # Rest at the deck, swell up, settle back: a full dive-and-surface loop.
        dy = -AMPLITUDE * (1 - math.cos(2 * math.pi * i / FRAMES)) / 2
        (frames / f"{i:02d}.svg").write_text(svg(dy))
    print(f"wrote assets/menubar.svg and {FRAMES} frames in assets/menubar-frames/")


if __name__ == "__main__":
    main()

# Beach's front and middle boulders, traced on the base art (art points,
# bottom-left fractions), as antialiased masks at the art's size.
# Run: uv run --with pillow python tools/author/art/beach/cuts/trace.py tools/author/art/beach/cuts
import json, sys
from PIL import Image, ImageDraw

W, H, SS = 2048, 1536, 4
OUTLINES = {
    "boulder-front": [(0.630, 0.188), (0.644, 0.210), (0.677, 0.226), (0.718, 0.232), (0.751, 0.229), (0.778, 0.216), (0.804, 0.195), (0.824, 0.169), (0.835, 0.144), (0.835, 0.115), (0.805, 0.107), (0.773, 0.106), (0.741, 0.115), (0.709, 0.124), (0.686, 0.135), (0.660, 0.142), (0.641, 0.148), (0.631, 0.157), (0.628, 0.170)],
    "boulder-middle": [(0.604, 0.255), (0.609, 0.279), (0.622, 0.297), (0.644, 0.305), (0.673, 0.307), (0.699, 0.301), (0.718, 0.283), (0.728, 0.264), (0.730, 0.246), (0.727, 0.236), (0.718, 0.231), (0.677, 0.226), (0.654, 0.229), (0.628, 0.238), (0.607, 0.246)],
}
out = sys.argv[1]
for name, pts in OUTLINES.items():
    m = Image.new("L", (W * SS, H * SS), 0)
    ImageDraw.Draw(m).polygon([(u * W * SS, (1 - v) * H * SS) for u, v in pts], fill=255)
    m.resize((W, H), Image.LANCZOS).save(f"{out}/{name}.png")
json.dump(OUTLINES, open(f"{out}/outlines.json", "w"), indent=1)

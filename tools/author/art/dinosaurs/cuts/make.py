# Dinosaurs' cut layers, made from the finished wide background
# (out/art/background-wide.png): the whole rock ledge, and the ginkgo with
# its horsetails and the bushes at its foot. Each is lifted out of a crop
# by Vision's subject lifting (lift.swift: their outlines follow every
# leaf and the rock's rim), the pieces joined, and mended with outlines
# traced by hand (base art points, bottom-left fractions): the ledge's flat
# top (a tuft on it), and a clip round the ginkgo clump. Masks at the wide
# art's size (the ledge runs past the 4:3 picture's right side).
# Run from tools/: python3 author/art/dinosaurs/cuts/make.py
import os, subprocess, tempfile
from PIL import Image, ImageChops, ImageDraw, ImageFilter

here = os.path.dirname(os.path.abspath(__file__))
bg = Image.open(os.path.join(here, "..", "out", "art", "background-wide.png")).convert("RGB")
W, H = bg.size

def px(u, v):
    return int((u / 1.5 + 1 / 6) * W), int((1 - v) * H)

def polygon(points):
    m = Image.new("L", (W, H), 0)
    ImageDraw.Draw(m).polygon([((u / 1.5 + 1 / 6) * W, (1 - v) * H) for u, v in points], fill=255)
    return m

def lifted(crops):
    """The union of the subjects Vision lifts out of each crop (left, top, right, bottom)."""
    out = Image.new("L", (W, H), 0)
    with tempfile.TemporaryDirectory() as tmp:
        for k, (a, b, c, d) in enumerate(crops):
            x0, y0 = px(a, b)
            x1, y1 = px(c, d)
            src, dst = os.path.join(tmp, f"{k}.png"), os.path.join(tmp, f"{k}.mask.png")
            bg.crop((x0, y0, x1, y1)).save(src)
            subprocess.run(["swift", os.path.join(here, "lift.swift"), src, dst], check=True, capture_output=True)
            piece = Image.new("L", (W, H), 0)
            piece.paste(Image.open(dst).convert("L"), (x0, y0))
            out = ImageChops.lighter(out, piece)
    return out

def close(m, n):
    return m.filter(ImageFilter.MaxFilter(n)).filter(ImageFilter.MinFilter(n))

# The ledge: the rock, and its flat top whole.
LEDGE_TOP = [(0.665, 0.370), (0.700, 0.389), (0.778, 0.394), (0.848, 0.394), (0.931, 0.392), (1.013, 0.387), (1.096, 0.383), (1.155, 0.375), (1.190, 0.360), (1.190, 0.350), (1.096, 0.346), (1.013, 0.342), (0.914, 0.339), (0.906, 0.334), (0.807, 0.334), (0.802, 0.345), (0.753, 0.350), (0.745, 0.359), (0.699, 0.367)]
ledge = close(ImageChops.lighter(lifted([(0.62, 0.42, 1.22, 0.20)]), polygon(LEDGE_TOP)), 3)
ledge.save(os.path.join(here, "ledge.png"))

# The ginkgo: the tree, the bushes left of it, the horsetails, the bush right of them.
GINKGO_CLIP = [(0.840, 0.400), (0.845, 0.440), (0.864, 0.458), (0.880, 0.481), (0.876, 0.504), (0.876, 0.526), (0.894, 0.560), (0.915, 0.592), (0.928, 0.606), (0.949, 0.606), (0.964, 0.588), (0.980, 0.578), (0.992, 0.560), (1.001, 0.545), (1.001, 0.515), (0.990, 0.500), (1.004, 0.464), (1.020, 0.455), (1.030, 0.430), (1.032, 0.400)]
ginkgo = close(lifted([(0.86, 0.62, 1.02, 0.39), (0.835, 0.475, 0.925, 0.395), (0.85, 0.485, 0.935, 0.395), (0.94, 0.515, 1.0, 0.395), (0.975, 0.48, 1.045, 0.395)]), 5)
ginkgo = ImageChops.multiply(ginkgo, polygon(GINKGO_CLIP).filter(ImageFilter.MaxFilter(9)))
# The meadow seen between its leaves stays behind.
x0, y0 = px(0.87, 0.60)
x1, y1 = px(1.0, 0.505)
P, M = bg.load(), ginkgo.load()
for y in range(y0, y1):
    for x in range(x0, x1):
        r, g, b = P[x, y]
        if M[x, y] and abs(r - g) < 28 and g > 130 and b < 100:
            M[x, y] = 0
ginkgo = ginkgo.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.MaxFilter(3))
ginkgo.save(os.path.join(here, "ginkgo.png"))

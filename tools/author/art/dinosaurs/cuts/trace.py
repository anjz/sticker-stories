# Dinosaurs' rock ledge (its cliff faces, not its flat top, where stickers
# stand) and the ginkgo clump (the ginkgo, the horsetails and the bushes
# round them), traced on the wide art in base art points (bottom-left
# fractions; the ledge runs past the 4:3 picture's right side), as
# antialiased masks at the wide art's size.
# Run: uv run --with pillow python tools/author/art/dinosaurs/cuts/trace.py tools/author/art/dinosaurs/cuts
import json, sys
from PIL import Image, ImageDraw

W, H, SS = 3072, 1536, 4
OUTLINES = {
    "ledge": [(0.662, 0.373), (0.699, 0.367), (0.745, 0.359), (0.753, 0.350), (0.802, 0.345), (0.807, 0.334), (0.906, 0.334), (0.914, 0.339), (1.013, 0.342), (1.055, 0.345), (1.096, 0.348), (1.195, 0.353), (1.200, 0.328), (1.158, 0.298), (1.096, 0.277), (1.013, 0.272), (0.910, 0.261), (0.848, 0.239), (0.794, 0.239), (0.782, 0.270), (0.724, 0.275), (0.645, 0.287), (0.641, 0.317), (0.654, 0.356)],
    "ginkgo": [(0.840, 0.400), (0.845, 0.440), (0.864, 0.458), (0.880, 0.481), (0.876, 0.504), (0.876, 0.526), (0.894, 0.560), (0.915, 0.592), (0.928, 0.606), (0.949, 0.606), (0.964, 0.588), (0.980, 0.578), (0.992, 0.560), (1.001, 0.545), (1.001, 0.515), (0.990, 0.500), (1.004, 0.464), (1.020, 0.455), (1.030, 0.430), (1.032, 0.400)],
}
out = sys.argv[1]
for name, pts in OUTLINES.items():
    m = Image.new("L", (W * SS, H * SS), 0)
    ImageDraw.Draw(m).polygon([((u / 1.5 + 1 / 6) * W * SS, (1 - v) * H * SS) for u, v in pts], fill=255)
    m.resize((W, H), Image.LANCZOS).save(f"{out}/{name}.png")
json.dump(OUTLINES, open(f"{out}/outlines.json", "w"), indent=1)

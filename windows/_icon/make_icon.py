"""Generates yt-grab.ico (multi-resolution) and yt-grab.png (preview).

Design: rounded red square, white play triangle, white down-arrow underneath.
Drawn at 4x scale (2048px) and downsampled for crisp anti-aliasing.
"""
from PIL import Image, ImageDraw
from pathlib import Path

OUT_DIR = Path(__file__).resolve().parent.parent
SCALE = 4
BASE = 512
SIZE = BASE * SCALE

RED = (220, 35, 35, 255)
RED_DARK = (175, 20, 20, 255)
WHITE = (255, 255, 255, 255)


def rounded_rect_mask(size, radius):
    img = Image.new("L", (size, size), 0)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return img


def make_master():
    radius = int(SIZE * 0.22)

    # Background gradient (top lighter, bottom darker)
    bg = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    grad = Image.new("RGBA", (SIZE, SIZE))
    for y in range(SIZE):
        t = y / SIZE
        r = int(RED[0] * (1 - t) + RED_DARK[0] * t)
        g = int(RED[1] * (1 - t) + RED_DARK[1] * t)
        b = int(RED[2] * (1 - t) + RED_DARK[2] * t)
        for x in range(SIZE):
            grad.putpixel((x, y), (r, g, b, 255))
    mask = rounded_rect_mask(SIZE, radius)
    bg.paste(grad, (0, 0), mask)

    d = ImageDraw.Draw(bg)

    # Play triangle — pointing right, top-centred
    cx = SIZE // 2
    cy_play = int(SIZE * 0.40)
    tri_h = int(SIZE * 0.30)
    tri_w = int(tri_h * 0.86)
    triangle = [
        (cx - tri_w // 2, cy_play - tri_h // 2),
        (cx - tri_w // 2, cy_play + tri_h // 2),
        (cx + tri_w // 2, cy_play),
    ]
    d.polygon(triangle, fill=WHITE)

    # Download arrow — vertical bar + arrowhead, underneath
    bar_w = int(SIZE * 0.08)
    bar_h = int(SIZE * 0.16)
    bar_top = int(SIZE * 0.62)
    d.rectangle(
        (cx - bar_w // 2, bar_top, cx + bar_w // 2, bar_top + bar_h),
        fill=WHITE,
    )

    head_w = int(SIZE * 0.26)
    head_h = int(SIZE * 0.14)
    head_top = bar_top + bar_h - int(SIZE * 0.01)
    arrowhead = [
        (cx - head_w // 2, head_top),
        (cx + head_w // 2, head_top),
        (cx, head_top + head_h),
    ]
    d.polygon(arrowhead, fill=WHITE)

    # Underline (the "ground" the arrow lands on)
    underline_y = int(SIZE * 0.84)
    underline_w = int(SIZE * 0.40)
    underline_h = int(SIZE * 0.04)
    d.rounded_rectangle(
        (
            cx - underline_w // 2,
            underline_y,
            cx + underline_w // 2,
            underline_y + underline_h,
        ),
        radius=underline_h // 2,
        fill=WHITE,
    )

    return bg


def main():
    print("Rendering master...")
    master = make_master()
    base = master.resize((BASE, BASE), Image.LANCZOS)

    png_path = OUT_DIR / "yt-grab.png"
    base.save(png_path, "PNG")
    print(f"PNG preview: {png_path}")

    sizes = [256, 128, 64, 48, 32, 16]
    icons = [base.resize((s, s), Image.LANCZOS) for s in sizes]
    ico_path = OUT_DIR / "yt-grab.ico"
    icons[0].save(
        ico_path,
        format="ICO",
        sizes=[(s, s) for s in sizes],
        append_images=icons[1:],
    )
    print(f"ICO: {ico_path}")


if __name__ == "__main__":
    main()

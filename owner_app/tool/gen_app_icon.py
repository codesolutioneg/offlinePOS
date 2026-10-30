from PIL import Image, ImageDraw

size = 1024
img = Image.new("RGBA", (size, size), (27, 40, 56, 255))
draw = ImageDraw.Draw(img)
cx = cy = size // 2
r = int(size * 0.38)

for i in range(8, 0, -1):
    a = int(40 * (i / 8))
    pad = int(r * 0.08 * i)
    draw.ellipse(
        [cx - r - pad, cy - r - pad, cx + r + pad, cy + r + pad],
        fill=(14, 165, 233, a),
    )

draw.ellipse([cx - r, cy - r, cx + r, cy + r], fill=(14, 165, 233, 255))
rin = int(r * 0.78)
draw.ellipse(
    [cx - rin, cy - rin, cx + rin, cy + rin],
    outline=(255, 255, 255, 220),
    width=max(6, size // 80),
)


def arc(d, color, start, end, width, radius, ox, oy):
    d.arc(
        [ox - radius, oy - radius, ox + radius, oy + radius],
        start=start,
        end=end,
        fill=color,
        width=width,
    )


arc(draw, (56, 189, 248, 255), -40, 100, max(10, size // 70), int(r * 0.92), cx, cy)
arc(draw, (3, 105, 161, 255), 140, 280, max(10, size // 70), int(r * 0.92), cx, cy)

rw, rh = int(r * 0.55), int(r * 0.72)
rx, ry = cx - rw // 2 + int(r * 0.12), cy - rh // 2 - int(r * 0.08)
draw.rounded_rectangle(
    [rx, ry, rx + rw, ry + rh],
    radius=max(8, size // 90),
    fill=(255, 255, 255, 255),
    outline=(14, 165, 233, 255),
    width=max(4, size // 120),
)
for i in range(4):
    y = ry + int(rh * (0.22 + i * 0.16))
    draw.rounded_rectangle(
        [rx + int(rw * 0.18), y, rx + int(rw * 0.82), y + max(6, size // 90)],
        radius=3,
        fill=(14, 165, 233, 255),
    )

out = r"d:\offlinePOS\owner_app\assets\brand\app_icon.png"
img.save(out, "PNG")
print("wrote", out)

fg = Image.new("RGBA", (size, size), (0, 0, 0, 0))
fd = ImageDraw.Draw(fg)
sr = int(size * 0.32)
scx = scy = size // 2
fd.ellipse([scx - sr, scy - sr, scx + sr, scy + sr], fill=(14, 165, 233, 255))
rin2 = int(sr * 0.78)
fd.ellipse(
    [scx - rin2, scy - rin2, scx + rin2, scy + rin2],
    outline=(255, 255, 255, 220),
    width=max(6, size // 90),
)
arc(fd, (56, 189, 248, 255), -40, 100, max(8, size // 80), int(sr * 0.92), scx, scy)
arc(fd, (3, 105, 161, 255), 140, 280, max(8, size // 80), int(sr * 0.92), scx, scy)
rw, rh = int(sr * 0.55), int(sr * 0.72)
rx, ry = scx - rw // 2 + int(sr * 0.1), scy - rh // 2 - int(sr * 0.06)
fd.rounded_rectangle(
    [rx, ry, rx + rw, ry + rh],
    radius=max(6, size // 100),
    fill=(255, 255, 255, 255),
    outline=(14, 165, 233, 255),
    width=max(3, size // 140),
)
for i in range(4):
    y = ry + int(rh * (0.22 + i * 0.16))
    fd.rounded_rectangle(
        [rx + int(rw * 0.18), y, rx + int(rw * 0.82), y + max(5, size // 100)],
        radius=3,
        fill=(14, 165, 233, 255),
    )
fg_out = r"d:\offlinePOS\owner_app\assets\brand\app_icon_foreground.png"
fg.save(fg_out, "PNG")
print("wrote", fg_out)

#!/usr/bin/env python3
"""生成微信多开助手 App 图标：两个叠放的对话气泡 + 加号，绿色渐变底。"""
from PIL import Image, ImageDraw

SIZE = 1024

img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# 圆角背景：绿→青渐变（竖向手绘渐变条）
grad = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
gd = ImageDraw.Draw(grad)
top = (23, 195, 110)     # #07C36E
bottom = (32, 170, 170)  # #20AAAA
for y in range(SIZE):
    t = y / SIZE
    r = int(top[0] + (bottom[0] - top[0]) * t)
    g = int(top[1] + (bottom[1] - top[1]) * t)
    b = int(top[2] + (bottom[2] - top[2]) * t)
    gd.line([(0, y), (SIZE, y)], fill=(r, g, b, 255))

mask = Image.new("L", (SIZE, SIZE), 0)
md = ImageDraw.Draw(mask)
md.rounded_rectangle([0, 0, SIZE - 1, SIZE - 1], radius=230, fill=255)
img.paste(grad, (0, 0), mask)


def bubble(draw, box, fill, outline=None, tail="left"):
    x0, y0, x1, y1 = box
    draw.rounded_rectangle(box, radius=int((y1 - y0) * 0.32), fill=fill, outline=outline, width=14)
    # 小尾巴
    tw = int((x1 - x0) * 0.16)
    th = int((y1 - y0) * 0.20)
    tx = x0 + int((x1 - x0) * 0.18) if tail == "left" else x1 - int((x1 - x0) * 0.18) - tw
    draw.polygon([(tx, y1 - 8), (tx + tw, y1 - 8), (tx + tw // 2, y1 + th)], fill=fill)


# 后面一个半透明白气泡（右上）
d2 = ImageDraw.Draw(img)
bubble(d2, (430, 210, 860, 560), (255, 255, 255, 120))
# 前面一个白色气泡（左下）
bubble(d2, (170, 330, 640, 700), (255, 255, 255, 255))
# 前气泡里画三个点（对话感）
for cx in (300, 405, 510):
    d2.ellipse([cx - 34, 480, cx + 34, 548], fill=(23, 195, 110, 255))

# 右下角加号徽章
badge_c = (790, 790)
badge_r = 150
d2.ellipse([badge_c[0] - badge_r, badge_c[1] - badge_r,
            badge_c[0] + badge_r, badge_c[1] + badge_r],
           fill=(255, 255, 255, 255))
bar_w, bar_h = 140, 34
d2.rounded_rectangle([badge_c[0] - bar_w // 2, badge_c[1] - bar_h // 2,
                      badge_c[0] + bar_w // 2, badge_c[1] + bar_h // 2],
                     radius=bar_h // 2, fill=(23, 195, 110, 255))
d2.rounded_rectangle([badge_c[0] - bar_h // 2, badge_c[1] - bar_w // 2,
                      badge_c[0] + bar_h // 2, badge_c[1] + bar_w // 2],
                     radius=bar_h // 2, fill=(23, 195, 110, 255))

img.save("icon_1024.png")
print("icon_1024.png saved")

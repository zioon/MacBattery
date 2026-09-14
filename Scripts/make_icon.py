#!/usr/bin/env python3
"""生成 MacBattery 应用图标。

几何比例、配色、分段圆环逻辑全部照搬 Sources/MacBattery/PowerHUDView.swift 的
一帧运行结果，因此改挂件 UI 后重跑本脚本即可得到同步的新图标。

用法:
    python Scripts/make_icon.py

产物:
    Resources/AppIcon.png           1024x1024 母版
    Resources/AppIcon.iconset/*.png macOS iconset
    Resources/AppIcon.icns          macOS 图标
"""

import io
import math
import os
import struct

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
OUT_DIR = os.path.join(ROOT, "Resources")

SIZE = 1024          # 输出边长
SS = 4               # 超采样倍数
N = SIZE * SS

# ---------------------------------------------------------------- 挂件比例
# 全部取自 PowerHUDView.swift 中相对 58pt 底框的比例
R_RING_W = 4.0 / 58.0
R_RING_CORNER = 14.0 / 58.0
R_INNER_W = 3.0 / 58.0
R_SYS_F = 12.0 / 58.0
R_SYS_UNIT = 6.5 / 58.0
R_CHG_F = 8.5 / 58.0
R_CHG_UNIT = 6.0 / 58.0
R_VGAP = 1.5 / 58.0
R_HGAP1 = 1.5 / 58.0
R_HGAP2 = 2.0 / 58.0

# ---------------------------------------------------------------- 图标那一帧
# 取值来自挂件真实运行截图（对照 Resources/实际运行图.png 实测各色段弧长）：
#   橙段 0→0.375、蓝段 0.375→0.5（CPU≈25%）、紫段 0.5→0.79（RAM≈58%）、右上缺口 0.79→1。
BATTERY = 0.375       # 电量，决定充电环颜色（<0.2 红 / <0.4 琥珀 / 其余绿）
CPU = 0.25            # CPU 占用，前半环（蓝段 0.375→0.5，与橙段严格相邻不重叠）
RAM = 0.58            # 内存占用，后半环（紫段 0.5→0.79，留出右上缺口）
SYS_W = "9.2"         # 整机功率
CHG_W = "9.6"         # 充电功率
CHARGING = True       # 充电中 -> 黄色闪电

# ---------------------------------------------------------------- 配色
BAR_RED = (255, 77, 77)        # Color(1.0, 0.30, 0.30)
BAR_AMBER = (255, 158, 46)     # Color(1.0, 0.62, 0.18)
BAR_GREEN = (51, 219, 115)     # Color(0.20, 0.86, 0.45)
CPU_BLUE = (64, 140, 255)      # Color(0.25, 0.55, 1.0)
RAM_PURPLE = (191, 89, 242)    # Color(0.75, 0.35, 0.95)
BOLT_ON = (255, 214, 10)
BOLT_OFF = (150, 155, 165)
BG_TOP = (33, 38, 48)
BG_BOTTOM = (9, 11, 15)


def bar_color(p):
    """对应 PowerHUDView.swift 中 barColor 的三档阈值。"""
    if p < 0.2:
        return BAR_RED
    if p < 0.4:
        return BAR_AMBER
    return BAR_GREEN


FONT_CANDIDATES = [
    r"C:\Windows\Fonts\ARLRDBD.TTF",   # Arial Rounded MT Bold，最接近 SF Rounded
    r"C:\Windows\Fonts\segoeuib.ttf",
    r"C:\Windows\Fonts\verdanab.ttf",
]

# 画布边长（1024 坐标系）
ICON_BOX = 824.0        # 图标方形外框（macOS 图标栅格 824/1024）
RING_BOX = 640.0        # 充电环外框

# 闪电多边形（归一化坐标）
BOLT = [(0.68, 0.00), (0.16, 0.56), (0.44, 0.56),
        (0.32, 1.00), (0.84, 0.42), (0.56, 0.42)]


# ---------------------------------------------------------------- 基础工具
def pick_font():
    for path in FONT_CANDIDATES:
        if os.path.exists(path):
            return path
    raise SystemExit("找不到可用字体: " + ", ".join(FONT_CANDIDATES))


def font(size_units):
    """size_units 为 1024 坐标系下的字号。"""
    return ImageFont.truetype(pick_font(), int(round(size_units * SS)))


def over(dst, rgb, alpha):
    """alpha over 合成；alpha 支持 (N,N) 或 (N,1)/(1,N) 广播。"""
    a = alpha[..., None] if alpha.ndim == 2 else alpha
    dst[..., :3] = rgb * a + dst[..., :3] * (1.0 - a)
    dst[..., 3:4] = a + dst[..., 3:4] * (1.0 - a)


def vramp(top, bottom, ya=0.0, yb=float(SIZE)):
    t = np.clip((np.arange(N, dtype=np.float32) / SS - ya) / (yb - ya), 0.0, 1.0)
    return (top + (bottom - top) * t)[:, None]


def color(c):
    return np.array(c, dtype=np.float32) / 255.0


def rr_mask(x0, y0, x1, y1, r):
    """圆角矩形实心 mask（1024 坐标）。"""
    img = Image.new("L", (N, N), 0)
    ImageDraw.Draw(img).rounded_rectangle(
        [x0 * SS, y0 * SS, x1 * SS, y1 * SS], radius=max(0.0, r) * SS, fill=255)
    return np.asarray(img, dtype=np.float32) / 255.0


def ring_band(x0, y0, x1, y1, r, w):
    """圆角矩形描边 band = 外圆角矩形 - 内圆角矩形，无接缝毛刺。"""
    outer = rr_mask(x0, y0, x1, y1, r)
    inner = rr_mask(x0 + w, y0 + w, x1 - w, y1 - w, r - w)
    return np.clip(outer - inner, 0.0, 1.0)


def rounded_rect_loop(x0, y0, x1, y1, r, seg=90):
    """圆角矩形周长折线，起点 = 右边中点、顺时针。

    起点与 SwiftUI RoundedRectangle 的 trim 起点一致（实测得到），
    因此 trim(from:to:) 的比例可直接作为本函数的 t 使用。
    """
    mid = (y0 + y1) / 2.0
    pts = [(x1, mid)]

    def arc(ccx, ccy, a0, a1):
        for i in range(seg + 1):
            a = math.radians(a0 + (a1 - a0) * i / seg)
            pts.append((ccx + r * math.cos(a), ccy + r * math.sin(a)))

    pts.append((x1, y1 - r))
    arc(x1 - r, y1 - r, 0.0, 90.0)
    pts.append((x0 + r, y1))
    arc(x0 + r, y1 - r, 90.0, 180.0)
    pts.append((x0, y0 + r))
    arc(x0 + r, y0 + r, 180.0, 270.0)
    pts.append((x1 - r, y0))
    arc(x1 - r, y0 + r, 270.0, 360.0)
    pts.append((x1, mid))
    return pts


def sub_path(pts, t0, t1):
    """按周长比例截取折线（t 从 0 起算，0 = 上边中点，顺时针）。"""
    p = np.asarray(pts, dtype=np.float64)
    seg = np.sqrt(((p[1:] - p[:-1]) ** 2).sum(axis=1))
    cum = np.concatenate([[0.0], np.cumsum(seg)])
    a, b = t0 * cum[-1], t1 * cum[-1]
    u = np.linspace(a, b, max(8, int((b - a) / 1.5) + 2))
    return np.stack([np.interp(u, cum, p[:, 0]), np.interp(u, cum, p[:, 1])], axis=1)


def band_mask(pts, width, round_cap=True):
    """沿折线的等宽带：带身用多边形，端帽用整圆求并，等价 lineCap: .round。"""
    p = np.asarray(pts, dtype=np.float64)
    tan = np.gradient(p, axis=0)
    norm = np.linalg.norm(tan, axis=1, keepdims=True)
    tan = tan / np.where(norm < 1e-9, 1.0, norm)
    nrm = np.stack([-tan[:, 1], tan[:, 0]], axis=1) * (width / 2.0)
    poly = [tuple(v) for v in (p + nrm)] + [tuple(v) for v in (p - nrm)[::-1]]
    img = Image.new("L", (N, N), 0)
    dr = ImageDraw.Draw(img)
    dr.polygon([(x * SS, y * SS) for (x, y) in poly], fill=255)
    if round_cap:
        r = width / 2.0
        for cx, cy in (p[0], p[-1]):
            dr.ellipse([(cx - r) * SS, (cy - r) * SS, (cx + r) * SS, (cy + r) * SS],
                       fill=255)
    return np.asarray(img, dtype=np.float32) / 255.0


def poly_mask(pts):
    img = Image.new("L", (N, N), 0)
    ImageDraw.Draw(img).polygon([(x * SS, y * SS) for (x, y) in pts], fill=255)
    return np.asarray(img, dtype=np.float32) / 255.0


def text_mask(s, f, x, y, anchor):
    img = Image.new("L", (N, N), 0)
    ImageDraw.Draw(img).text((x * SS, y * SS), s, fill=255, font=f, anchor=anchor)
    return np.asarray(img, dtype=np.float32) / 255.0


def soft(dst, mask, rgb, radius, alpha):
    """半分辨率高斯模糊柔光，避免在 4096 上做大半径模糊。"""
    small = Image.fromarray((np.clip(mask, 0, 1) * 255).astype(np.uint8))
    small = small.resize((SIZE // 2, SIZE // 2), Image.BILINEAR)
    small = small.filter(ImageFilter.GaussianBlur(radius / 2.0))
    big = np.asarray(small.resize((N, N), Image.BILINEAR), dtype=np.float32) / 255.0
    over(dst, rgb, big * alpha)


# ---------------------------------------------------------------- 绘制
def render():
    # 环的几何：与 PowerHUDView 的 ringStrokeRadius / innerRingInset 推导一致
    x0 = y0 = (SIZE - RING_BOX) / 2.0
    x1 = y1 = x0 + RING_BOX
    ring_w = R_RING_W * RING_BOX
    ring_corner = R_RING_CORNER * RING_BOX
    charge_inner_r = ring_corner - ring_w           # 充电环内壁圆角
    inner_w = R_INNER_W * RING_BOX
    inner_inset = ring_w + inner_w / 2.0            # 内环路径内缩

    canvas = np.zeros((N, N, 4), dtype=np.float32)

    # 1) 图标底盘：与充电环严格平行的圆角矩形 + 深色玻璃竖向渐变 + 左上柔光
    #    同心的圆角矩形只要「圆角差 = 外框差 / 2」就是一对平行等距曲线，
    #    于是底盘、充电环内外缘、内环内外缘、CPU/RAM 的法向间距处处相等。
    b0, b1 = (SIZE - ICON_BOX) / 2.0, (SIZE + ICON_BOX) / 2.0
    bg_corner = ring_corner + (x0 - b0)
    sq = rr_mask(b0, b0, b1, b1, bg_corner)
    g = np.linspace(0.0, 1.0, N, dtype=np.float32)[:, None]
    bg = np.empty((N, N, 3), dtype=np.float32)
    for ch in range(3):
        bg[..., ch] = (BG_TOP[ch] + (BG_BOTTOM[ch] - BG_TOP[ch]) * g) / 255.0
    xg = (np.arange(N, dtype=np.float32) / SS / SIZE)[None, :]
    yg = (np.arange(N, dtype=np.float32) / SS / SIZE)[:, None]
    sheen = np.exp(-(((xg - 0.30) ** 2 + (yg - 0.16) ** 2) / 0.16)).astype(np.float32)
    bg += sheen[..., None] * 0.13
    over(canvas, bg, sq)

    # 2) 边缘高光：同样按平行等距内缩，拉出玻璃厚度
    rim = np.clip(sq - rr_mask(b0 + 3, b0 + 3, b1 - 3, b1 - 3, bg_corner - 3), 0.0, 1.0)
    over(canvas, color((255, 255, 255)), rim * vramp(0.22, 0.0))

    # 3) 环内的半透明暗底盘（挂件里的 black 0.32）
    over(canvas, np.zeros(3, dtype=np.float32),
         rr_mask(x0, y0, x1, y1, ring_corner) * 0.22)

    # 4) 外层充电环底环（white 0.28；深色图标上稍提亮到 0.32 以增强轨道感）
    over(canvas, color((255, 255, 255)),
         ring_band(x0, y0, x1, y1, ring_corner, ring_w) * 0.32)

    # 5) 内层 CPU / RAM 底环（white 0.15；提亮到 0.22，对照运行图的轨道层次）
    ib0, ib1 = x0 + ring_w, x1 - ring_w
    over(canvas, color((255, 255, 255)),
         ring_band(ib0, ib0, ib1, ib1, charge_inner_r, inner_w) * 0.22)

    # 6) 电量进度弧：trim(0, progress) + 自上而下 1.0 -> 0.75 的透明度渐变。
    #    运行图里橙段底部约 0.66 亮度（非 0.55），过度渐变会让底部橙发灰、
    #    左下角 CPU 蓝被吞没；故收窄渐变区间并减弱光晕。
    path = rounded_rect_loop(x0 + ring_w / 2, y0 + ring_w / 2,
                             x1 - ring_w / 2, y1 - ring_w / 2, ring_corner - ring_w)
    arc = band_mask(sub_path(path, 0.0, BATTERY), ring_w)
    bar = color(bar_color(BATTERY))
    soft(canvas, arc, bar, 18.0, 0.10)
    over(canvas, bar, arc * vramp(1.0, 0.75, y0, y1))

    # 7) 内环：CPU 前半环反向生长、RAM 后半环正向生长，同基点 0.5
    ipath = rounded_rect_loop(x0 + inner_inset, y0 + inner_inset,
                              x1 - inner_inset, y1 - inner_inset,
                              charge_inner_r - inner_w)
    cpu = band_mask(sub_path(ipath, 0.5 - 0.5 * CPU, 0.5), inner_w)
    ram = band_mask(sub_path(ipath, 0.5, 0.5 + 0.5 * RAM), inner_w)
    soft(canvas, cpu, color(CPU_BLUE), 12.0, 0.15)
    soft(canvas, ram, color(RAM_PURPLE), 12.0, 0.15)
    over(canvas, color(CPU_BLUE), cpu)
    over(canvas, color(RAM_PURPLE), ram)

    # 8) 中间两行功率（1024 坐标布局，字体按 SS 放大后绘制）
    cx = SIZE / 2.0
    f_sys = font(R_SYS_F * RING_BOX)
    f_sys_u = font(R_SYS_UNIT * RING_BOX)
    f_chg = font(R_CHG_F * RING_BOX)
    f_chg_u = font(R_CHG_UNIT * RING_BOX)

    tw = lambda f, s: f.getlength(s) / SS
    lh = lambda f: sum(f.getmetrics()) / SS
    asc = lambda f: f.getmetrics()[0] / SS

    bolt_sz = R_SYS_UNIT * RING_BOX
    h1, h2 = lh(f_sys), lh(f_chg)
    gap = R_VGAP * RING_BOX
    top = cx - (h1 + gap + h2) / 2.0
    base1 = top + asc(f_sys)
    y2 = top + h1 + gap + h2 / 2.0

    w_num = tw(f_sys, SYS_W)
    hg1 = R_HGAP1 * RING_BOX
    w1 = w_num + hg1 + tw(f_sys_u, "W")
    xs1 = cx - w1 / 2.0
    over(canvas, color((255, 255, 255)), text_mask(SYS_W, f_sys, xs1, base1, "ls"))
    over(canvas, color((255, 255, 255)),
         text_mask("W", f_sys_u, xs1 + w_num + hg1, base1, "ls") * 0.6)

    w_chg = tw(f_chg, CHG_W)
    hg2 = R_HGAP2 * RING_BOX
    w2 = bolt_sz + hg2 + w_chg + hg2 + tw(f_chg_u, "W")
    xs2 = cx - w2 / 2.0
    pad = 0.05
    bx, by = xs2 + pad * bolt_sz, y2 - bolt_sz / 2.0 + pad * bolt_sz
    side = bolt_sz * (1 - 2 * pad)
    bolt = [(bx + px * side, by + py * side) for (px, py) in BOLT]
    bm = poly_mask(bolt)
    bcol = color(BOLT_ON if CHARGING else BOLT_OFF)
    soft(canvas, bm, bcol, 16.0, 0.26)
    over(canvas, bcol, bm)

    tx = xs2 + bolt_sz + hg2
    over(canvas, color((255, 255, 255)), text_mask(CHG_W, f_chg, tx, y2, "lm") * 0.9)
    over(canvas, color((255, 255, 255)),
         text_mask("W", f_chg_u, tx + w_chg + hg2, y2, "lm") * 0.5)

    # ------------------------------------------------------------ 输出
    out = np.concatenate([np.clip(canvas[..., :3], 0.0, 1.0),
                          np.clip(canvas[..., 3:4], 0.0, 1.0)], axis=2)
    img = Image.fromarray((out * 255.0 + 0.5).astype(np.uint8), "RGBA")
    return img.resize((SIZE, SIZE), Image.LANCZOS)


ICONSET = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

ICNS_TYPES = [("ic11", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256),
              ("ic14", 512), ("ic08", 256), ("ic09", 512), ("ic10", 1024)]


def write_outputs(img):
    os.makedirs(OUT_DIR, exist_ok=True)
    master = os.path.join(OUT_DIR, "AppIcon.png")
    img.save(master)

    iconset = os.path.join(OUT_DIR, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for name, px in ICONSET:
        img.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))

    body = b""
    for code, px in ICNS_TYPES:
        buf = io.BytesIO()
        img.resize((px, px), Image.LANCZOS).save(buf, "PNG")
        data = buf.getvalue()
        body += code.encode("ascii") + struct.pack(">I", len(data) + 8) + data
    icns = b"icns" + struct.pack(">I", len(body) + 8) + body
    icns_path = os.path.join(OUT_DIR, "AppIcon.icns")
    with open(icns_path, "wb") as fh:
        fh.write(icns)

    return master, icns_path, iconset


if __name__ == "__main__":
    for p in write_outputs(render()):
        print("wrote", p)

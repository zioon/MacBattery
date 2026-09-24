#!/usr/bin/env python3
"""生成 MacBattery 应用图标。

几何比例、配色、分段圆环逻辑全部照搬 Sources/MacBattery/PowerHUDView.swift 的
一帧运行结果，因此改挂件 UI 后重跑本脚本即可得到同步的新图标。

本版图形对照的挂件状态（2026-09-24 的运行截图）：
    电量 100%（环满格、薄荷绿）、CPU ≈ 24.5%、RAM ≈ 53.4%、
    三行读数 9.1 W / ⚡ 0:06 / 剩余 4:42。

底盘有两套（`THEME` 切换）：`light` 浅色玻璃（对应挂件压在浅色桌面上的样子，
即那张截图）、`dark` 深色玻璃。两套只用同一份几何，换底盘不动图形。

用法:
    python Scripts/make_icon.py

依赖:
    pip install pillow numpy

产物:
    Resources/AppIcon.png           1024x1024 母版
    Resources/AppIcon.iconset/*.png macOS iconset
    Resources/AppIcon.icns          macOS 图标（CI 会把它塞进 .app 的 Resources/）
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
# 全部取自 PowerHUDView.swift 中相对 58pt 底框的比例。
# 图标里「挂件的 58pt 底盘」= ICON_BOX，于是所有元素与挂件同比例放大，
# 改挂件尺寸时只要 ICON_BOX 不变，图形就不会走样。
R_RING_W = 4.0 / 58.0
R_INNER_W = 3.0 / 58.0
R_SYS_F = 12.0 / 58.0       # 整机功率
R_SYS_UNIT = 6.5 / 58.0     # 单位 W
R_CHG_F = 8.5 / 58.0        # 第二行数值
R_REM_F = 5.5 / 58.0        # 第三行「剩余 h:mm」
R_VGAP = 1.5 / 58.0         # 三行之间的行距
R_HGAP1 = 1.5 / 58.0        # 数值 ↔ 单位 W
R_HGAP2 = 2.0 / 58.0        # 闪电 ↔ 第二行数值
R_HGAP3 = 1.4 / 58.0        # 「剩余」 ↔ 时长

# ---------------------------------------------------------------- 图标那一帧
# 弧长取自挂件运行截图实测（占各自半环的比例）：
#   蓝段（CPU）占上半环 24.5%、紫段（RAM）占下半环 53.4%，
#   两段共用同一基点 = 内环的「右边中点」。
LEVEL = 1.00          # 电量：1.0 -> 充电环满格薄荷绿
CPU = 0.2453          # CPU 弧长占「上半环」的比例（自右边中点向上生长）
RAM = 0.5343          # RAM 弧长占「下半环」的比例（自右边中点向下生长）
SYS_W = "9.1"         # 整机功率
CHG_T = "0:06"        # 使用电池时长
REM_LABEL = "剩余"     # 预计剩余时间的前缀
REM_T = "4:42"

# ---------------------------------------------------------------- 配色
# 环色与 PowerHUDView.levelColor(1.0) / cpuColor / ramColor 的 sRGB 值一致，两套底盘共用。
LEVEL_GREEN = (41, 217, 158)    # Color(0.16, 0.85, 0.62)
CPU_BLUE = (64, 140, 255)       # Color(0.25, 0.55, 1.0)
RAM_PURPLE = (191, 89, 242)     # Color(0.75, 0.35, 0.95)
GLOW_RADIUS = 18.0              # 环色柔光（挂件充电时的 levelColor 外发光）
GLOW_ALPHA = 0.18

# 底盘两套。挂件的底盘是「半透明黑 + 毛玻璃」（black 0.32），压在浅色桌面上就成了
# 截图里那个灰（实测 #ADADAD = 255×0.68），压在深色桌面上则是深色玻璃。
# 图标不能半透明，所以两套各自做成不透明表面，文字色随之反转（浅底上白字对比度
# 只有约 2:1，是截图里唯一不可用的地方，必须改成深墨）。
THEME = "light"                 # "light" | "dark"

PALETTES = {
    "dark": {
        "plate": [(0.00, (44, 50, 62)), (0.55, (25, 30, 38)), (1.00, (14, 17, 22))],
        "ink": (255, 255, 255),     # 文字 / 闪电：white 1.0|0.9|0.6
        "track_inner": 0.15,        # 内环底环：挂件的 white 0.15
        "track_outer": 0.28,        # 充电环底环：挂件的 white 0.28
    },
    "light": {
        # 浅色玻璃：顶端偏白、底端落回截图里那个灰（#AEB6BF ≈ 截图底盘 #ADADAD）
        "plate": [(0.00, (216, 222, 228)), (0.55, (196, 203, 211)), (1.00, (174, 182, 191))],
        "ink": (31, 36, 44),        # 深墨，替掉白字
        "track_inner": 0.34,        # 底环仍比底盘亮（与截图同向），浅底上要提亮才看得见
        "track_outer": 0.34,
    },
}


def level_color(p):
    """对应 PowerHUDView.levelColor(for:)：0 红 → 100% 薄荷绿，分段线性插值。"""
    stops = [(0.00, (255, 59, 48)), (0.20, (255, 107, 46)), (0.40, (255, 191, 51)),
             (0.60, (158, 230, 64)), (0.80, (61, 224, 107)), (1.00, (41, 217, 158))]
    p = min(max(p, 0.0), 1.0)
    for (pa, ca), (pb, cb) in zip(stops, stops[1:]):
        if p <= pb:
            t = (p - pa) / (pb - pa) if pb > pa else 0.0
            return tuple(int(round(ca[i] + (cb[i] - ca[i]) * t)) for i in range(3))
    return stops[-1][1]


LATIN_FONT_CANDIDATES = [
    r"C:\Windows\Fonts\ARLRDBD.TTF",                        # Arial Rounded MT Bold
    "/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf",
    r"C:\Windows\Fonts\segoeuib.ttf",
    r"C:\Windows\Fonts\verdanab.ttf",
    "/System/Library/Fonts/Supplemental/Verdana Bold.ttf",
]

CJK_FONT_CANDIDATES = [
    r"C:\Windows\Fonts\msyh.ttc",                            # 微软雅黑
    r"C:\Windows\Fonts\msyhbd.ttc",
    r"C:\Windows\Fonts\simhei.ttf",
    "/System/Library/Fonts/PingFang.ttc",                    # 苹方
    "/System/Library/Fonts/Hiragino Sans GB.ttc",
]

# 画布边长（1024 坐标系）
ICON_BOX = 824.0        # 图标方形外框（macOS 图标栅格 824/1024）
TILE_CORNER = 185.0     # 外框圆角（≈ macOS 图标栅格的 185/824）

# 闪电多边形（归一化坐标，取自与设计稿一致的轮廓；外框 61x78）
BOLT = [(52 / 61.0, 0.00), (8 / 61.0, 45 / 78.0), (32 / 61.0, 45 / 78.0),
        (23 / 61.0, 78 / 78.0), (61 / 61.0, 30 / 78.0), (36 / 61.0, 30 / 78.0)]
BOLT_ASPECT = 61.0 / 78.0


# ---------------------------------------------------------------- 基础工具
def pick_font(candidates):
    for path in candidates:
        if os.path.exists(path):
            return path
    raise SystemExit("找不到可用字体: " + ", ".join(candidates))


def font(path, size_units):
    """size_units 为 1024 坐标系下的字号。"""
    return ImageFont.truetype(path, int(round(size_units * SS)))


def over(dst, rgb, alpha):
    """alpha over 合成；alpha 支持 (N,N) 或 (N,1)/(1,N) 广播。"""
    a = alpha[..., None] if alpha.ndim == 2 else alpha
    dst[..., :3] = rgb * a + dst[..., :3] * (1.0 - a)
    dst[..., 3:4] = a + dst[..., 3:4] * (1.0 - a)


def vgrad(stops):
    """按 (位置, rgb) 停靠点做竖向渐变。"""
    t = np.arange(N, dtype=np.float32) / (SS * SIZE)
    out = np.empty((N, N, 3), dtype=np.float32)
    pos = [s[0] for s in stops]
    for ch in range(3):
        val = [s[1][ch] / 255.0 for s in stops]
        out[..., ch] = np.interp(t, pos, val)[:, None]
    return out


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
    """按周长比例截取折线（t = 0 在右边中点，顺时针）。"""
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
    latin = pick_font(LATIN_FONT_CANDIDATES)
    cjk = pick_font(CJK_FONT_CANDIDATES)
    pal = PALETTES[THEME]
    INK = color(pal["ink"])
    WHITE = color((255, 255, 255))

    # 环的几何：与 PowerHUDView 的 ringStrokeRadius / innerRingInset 推导一致。
    # 挂件的充电环外壁与底盘外壁重合，所以充电环外框 = 图标外框 ICON_BOX。
    x0 = y0 = (SIZE - ICON_BOX) / 2.0
    x1 = y1 = x0 + ICON_BOX
    ring_w = R_RING_W * ICON_BOX
    charge_inner_r = TILE_CORNER - ring_w        # 充电环内壁圆角
    inner_w = R_INNER_W * ICON_BOX
    inner_inset = ring_w + inner_w / 2.0         # 内环路径内缩

    canvas = np.zeros((N, N, 4), dtype=np.float32)

    # 1) 图标底盘 = 挂件的半透明暗底盘（截图里那层灰就是它压在浅色桌面上的样子，
    #    这里把它还原成深色玻璃并给一层竖向渐变）。
    #    同心圆角矩形只要「圆角差 = 外框差 / 2」就是一对平行等距曲线，于是底盘、
    #    充电环内外缘、内环内外缘、CPU/RAM 的法向间距处处相等。
    bg = vgrad(pal["plate"])
    over(canvas, bg, rr_mask(x0, y0, x1, y1, TILE_CORNER))

    # 2) 外层充电环底环（挂件的 white 0.28；<100% 时才是可见轨道，100% 会被进度弧盖满）
    over(canvas, WHITE,
         ring_band(x0, y0, x1, y1, TILE_CORNER, ring_w) * pal["track_outer"])

    # 3) 电量进度弧：trim(0, LEVEL)。100% 时整圈被覆盖，底环仅作为 <100% 时的轨道。
    bar = color(level_color(LEVEL))
    path = rounded_rect_loop(x0 + ring_w / 2, y0 + ring_w / 2,
                             x1 - ring_w / 2, y1 - ring_w / 2, TILE_CORNER - ring_w / 2)
    arc = band_mask(sub_path(path, 0.0, LEVEL), ring_w)
    soft(canvas, arc, bar, GLOW_RADIUS, GLOW_ALPHA)
    over(canvas, bar, arc)

    # 4) 内层 CPU / RAM 底环（挂件的 white 0.15；浅色底盘上同向提亮，否则看不见）
    ib0, ib1 = x0 + ring_w, x1 - ring_w
    over(canvas, WHITE,
         ring_band(ib0, ib0, ib1, ib1, charge_inner_r, inner_w) * pal["track_inner"])

    # 5) 内环：CPU 上半环自右边中点反向生长、RAM 下半环自同一点正向生长。
    #    t = 0 在右边中点；上半环 = t 0.5→1.0（跨顶边到右边中点），
    #    下半环 = t 0.0→0.5。故 CPU 取 1-0.5*cpu → 1、RAM 取 0 → 0.5*ram。
    ipath = rounded_rect_loop(x0 + inner_inset, y0 + inner_inset,
                              x1 - inner_inset, y1 - inner_inset,
                              TILE_CORNER - inner_inset)
    cpu = band_mask(sub_path(ipath, 1.0 - 0.5 * CPU, 1.0), inner_w)
    ram = band_mask(sub_path(ipath, 0.0, 0.5 * RAM), inner_w)
    soft(canvas, cpu, color(CPU_BLUE), 12.0, 0.15)
    soft(canvas, ram, color(RAM_PURPLE), 12.0, 0.15)
    over(canvas, color(CPU_BLUE), cpu)
    over(canvas, color(RAM_PURPLE), ram)

    # 6) 中间三行读数（按挂件的 VStack：行距 R_VGAP，基线 / 中线对齐方式照搬）
    cx = SIZE / 2.0
    f_sys = font(latin, R_SYS_F * ICON_BOX)
    f_sys_u = font(latin, R_SYS_UNIT * ICON_BOX)
    f_chg = font(latin, R_CHG_F * ICON_BOX)
    f_rem = font(latin, R_REM_F * ICON_BOX)
    f_rem_cjk = font(cjk, R_REM_F * ICON_BOX)

    tw = lambda f, s: f.getlength(s) / SS
    lh = lambda f: sum(f.getmetrics()) / SS
    asc = lambda f: f.getmetrics()[0] / SS

    bolt_h = R_REM_F * ICON_BOX
    bolt_w = bolt_h * BOLT_ASPECT
    hg1 = R_HGAP1 * ICON_BOX
    hg2 = R_HGAP2 * ICON_BOX
    hg3 = R_HGAP3 * ICON_BOX

    h1 = lh(f_sys)
    h2 = max(lh(f_chg), bolt_h)
    h3 = max(lh(f_rem), lh(f_rem_cjk))
    gap = R_VGAP * ICON_BOX
    top = (SIZE - (h1 + gap + h2 + gap + h3)) / 2.0

    # 第一行：9.1 + W（同基线，第一行是整机的「主读数」）
    base1 = top + asc(f_sys)
    w_num = tw(f_sys, SYS_W)
    w_1 = w_num + hg1 + tw(f_sys_u, "W")
    xs1 = cx - w_1 / 2.0
    over(canvas, INK, text_mask(SYS_W, f_sys, xs1, base1, "ls"))
    over(canvas, INK,
         text_mask("W", f_sys_u, xs1 + w_num + hg1, base1, "ls") * 0.6)

    # 第二行：闪电 + 时长（垂直居中）
    y2 = top + h1 + gap + h2 / 2.0
    w_chg = tw(f_chg, CHG_T)
    w_2 = bolt_w + hg2 + w_chg
    xs2 = cx - w_2 / 2.0
    by = y2 - bolt_h / 2.0
    bolt = [(xs2 + px * bolt_w, by + py * bolt_h) for (px, py) in BOLT]
    bm = poly_mask(bolt)
    # 闪电的柔光固定用白：深底上是高光、浅底上把字形从底盘里"托"出来
    soft(canvas, bm, WHITE, 16.0, 0.20)
    over(canvas, INK, bm * 0.5)
    over(canvas, INK,
         text_mask(CHG_T, f_chg, xs2 + bolt_w + hg2, y2, "lm") * 0.9)

    # 第三行：剩余 + 时长（与第二行同为「次要信息」，同为 white 0.6）
    y3 = top + h1 + gap + h2 + gap + h3 / 2.0
    w_lab = tw(f_rem_cjk, REM_LABEL)
    w_3 = w_lab + hg3 + tw(f_rem, REM_T)
    xs3 = cx - w_3 / 2.0
    over(canvas, INK,
         text_mask(REM_LABEL, f_rem_cjk, xs3, y3, "lm") * 0.6)
    over(canvas, INK,
         text_mask(REM_T, f_rem, xs3 + w_lab + hg3, y3, "lm") * 0.6)

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

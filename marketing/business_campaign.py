"""Editorial portrait with a true-scale device and a native glass close-up."""
from functools import lru_cache
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SOURCE = Path(__file__).resolve().parent / 'source'
INK = '#172528'
TEAL = '#286B65'
GRAY = '#677573'
PAPER = '#F2F3EF'

FEATURES = (
    ('额度监控', '重置前的使用节奏，心里有数。'),
    ('模型速度监控', '看看你的 6.1 sol 有没有磨洋工。'),
    ('任务状态监控', '思考、回复、调用工具，一眼看清。'),
    ('重置券监控', '盯紧到期时间，避开 Tibo Reset 陷阱。'),
    ('Credit 监控', 'Pro 用户人均 62,500，余额随时掌握。'),
)


@lru_cache(maxsize=1)
def desktop():
    # Native capture: 440 pt panel on a 1728 pt desktop (25.46% width).
    # Keep the material, refraction and shadows in the captured desktop pixels;
    # never scale the panel independently or add an opaque background to it.
    return Image.open(SOURCE / 'desktop-liquid-glass.png').convert('RGBA')


@lru_cache(maxsize=1)
def device():
    im = Image.open(SOURCE / 'macbook-studio.png').convert('RGBA')
    # Hardware geometry measured from the studio asset. The top-attached notch
    # remains visible above the native UI at the original desktop proportion.
    # Match the photographed screen's bounds by trimming only lower wallpaper,
    # never by stretching the UI. Screen width and native panel aspect stay exact.
    source = desktop()
    screen = source.crop((0, 0, source.width, round(source.width * 624 / 1056)))
    screen = screen.resize((1056, 624), Image.Resampling.LANCZOS)
    mask = Image.new('L', screen.size)
    d = ImageDraw.Draw(mask)
    d.rounded_rectangle((0, 0, 1055, 623), radius=16, fill=255)
    d.rounded_rectangle((468, -20, 587, 20), radius=7, fill=0)
    d.rectangle((468, -20, 587, 7), fill=0)
    screen.putalpha(mask)
    im.alpha_composite(screen, (241, 108))
    return im


@lru_cache(maxsize=1)
def closeup():
    # Content-only photographic detail: no duplicated hardware/notch. The
    # native glass and its wallpaper remain one continuous captured region.
    crop = desktop().crop((1248, 0, 2208, 1164))
    inner = Image.new('L', crop.size)
    ImageDraw.Draw(inner).rounded_rectangle((0, 0, 959, 1163), radius=26, fill=255)
    crop.putalpha(inner)
    frame = Image.new('RGBA', (984, 1188), '#F9FAF7')
    frame.alpha_composite(crop, (12, 12))
    mask = Image.new('L', frame.size)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, 983, 1187), radius=38, fill=255)
    frame.putalpha(mask)
    return frame


@lru_cache(maxsize=1)
def scene():
    im = Image.new('RGBA', (1600, 2400))
    d = ImageDraw.Draw(im)
    # Device and detail share one baseline, with a quiet optical link between
    # them. The inset enlarges the whole captured region, not the UI in the Mac.
    glow = Image.new('RGBA', im.size)
    gd = ImageDraw.Draw(glow)
    gd.ellipse((50, 1240, 1430, 1530), fill=(139, 159, 153, 20))
    im.alpha_composite(glow.filter(ImageFilter.GaussianBlur(72)))
    laptop = device().resize((950, 633), Image.Resampling.LANCZOS)
    im.alpha_composite(laptop, (-10, 893))

    link = Image.new('RGBA', im.size)
    ld = ImageDraw.Draw(link)
    points = []
    for step in range(65):
        t = step / 64
        x = (1-t)**3*550 + 3*(1-t)**2*t*662 + 3*(1-t)*t*t*743 + t**3*849
        y = (1-t)**3*1070 + 3*(1-t)**2*t*1070 + 3*(1-t)*t*t*999 + t**3*999
        points.append((x, y))
    ld.line(points, fill=(80, 119, 108, 130), width=2)
    ld.ellipse((545, 1065, 555, 1075), fill=PAPER, outline='#80998E', width=2)
    im.alpha_composite(link)

    detail = closeup().resize((640, 773), Image.Resampling.LANCZOS)
    shadow = Image.new('RGBA', im.size)
    sd = ImageDraw.Draw(shadow)
    sd.rounded_rectangle((849, 719, 1487, 1489), radius=28, fill=(42, 61, 54, 36))
    im.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(27)))
    im.alpha_composite(detail, (848, 696))
    d.rounded_rectangle((848, 696, 1487, 1468), radius=25, outline='#D4DDD6', width=1)

    return im.crop((0, 620, 1600, 1580))


def render(assets, font):
    w, h = 1600, 2400
    im = Image.new('RGBA', (w, h), PAPER)
    d = ImageDraw.Draw(im)

    def label(x, y, copy, size, color=INK, bold=False, anchor=None):
        d.text((x, y), copy, font=font(size, bold), fill=color, anchor=anchor)

    logo = assets('logo').resize((65, 65), Image.Resampling.LANCZOS)
    im.alpha_composite(logo, (112, 104))
    label(194, 110, 'Codex Pacer', 45, bold=True)
    label(1488, 124, '2.0 正式版', 28, GRAY, anchor='ra')
    d.line((112, 217, 1488, 217), fill='#D1DAD5', width=2)

    label(112, 272, '贴合 Mac 刘海的原生灵动岛', 32, TEAL)
    label(106, 335, '任务、额度，', 112, bold=True)
    label(106, 475, '抬眼即见。', 112, TEAL, True)

    im.alpha_composite(scene(), (0, 620))

    label(112, 1618, '五项监控，一目了然。', 38, INK, True)
    label(1488, 1630, '专注眼前的工作', 27, GRAY, anchor='ra')
    d.line((112, 1694, 1488, 1694), fill='#BECBC5', width=2)
    for i, (heading, caption) in enumerate(FEATURES):
        y = 1725 + i * 111
        label(112, y + 6, f'{i+1:02}', 24, '#8B9D94')
        label(183, y, heading, 33, INK, True)
        label(625, y + 2, caption, 29, GRAY)
        if i < len(FEATURES) - 1:
            d.line((183, y + 81, 1488, y + 81), fill='#D9E1DC', width=1)
    return im.convert('RGB')


def render_landscape(assets, font):
    im = Image.new('RGBA', (1920, 1080), PAPER)
    d = ImageDraw.Draw(im)
    def label(x, y, copy, size, color=INK, bold=False, anchor=None):
        d.text((x, y), copy, font=font(size, bold), fill=color, anchor=anchor)
    im.alpha_composite(assets('logo').resize((62, 62), Image.Resampling.LANCZOS), (94, 64))
    label(174, 69, 'Codex Pacer', 44, bold=True)
    label(1826, 82, '2.0 正式版', 27, GRAY, anchor='ra')
    d.line((94, 164, 1826, 164), fill='#D1DAD5', width=2)
    label(94, 215, '贴合 Mac 刘海的原生灵动岛', 29, TEAL)
    label(87, 276, '任务、额度，', 88, bold=True)
    label(87, 386, '抬眼即见。', 88, TEAL, True)
    im.alpha_composite(scene().resize((1100, 660), Image.Resampling.LANCZOS), (810, 244))
    for i, (heading, caption) in enumerate(FEATURES):
        y = 567 + i * 79
        label(94, y + 5, f'{i+1:02}', 20, '#8B9D94')
        label(145, y, heading, 27, INK, True)
        label(365, y + 3, caption, 23, GRAY)
        if i < len(FEATURES) - 1:
            d.line((145, y + 59, 800, y + 59), fill='#D9E1DC', width=1)
    return im.convert('RGB')

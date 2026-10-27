"""Render the fork's TV/play icon; no upstream logo artwork is used.

Run from the repository root with Python and Pillow installed. Existing launcher
filenames and dimensions are retained for platform build compatibility.
"""
from pathlib import Path
from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
BACKGROUND = '#171d25'
ACCENT = '#90caf9'


def icon(size, transparent=False):
    scale = 4
    canvas = Image.new('RGBA', (size * scale, size * scale),
                       (0, 0, 0, 0) if transparent else BACKGROUND)
    draw = ImageDraw.Draw(canvas)
    unit = size * scale / 108

    def points(values):
        return [(round(x * unit), round(y * unit)) for x, y in values]

    draw.rounded_rectangle([27 * unit, 35 * unit, 81 * unit, 73 * unit],
                           radius=4 * unit, outline=ACCENT, width=round(4 * unit))
    draw.line(points([(43, 26), (54, 35), (65, 26)]), fill=ACCENT,
              width=round(4 * unit), joint='curve')
    draw.line(points([(45, 81), (63, 81)]), fill=ACCENT, width=round(4 * unit))
    draw.polygon(points([(48, 44), (65, 54), (48, 64)]), fill=ACCENT)
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def main():
    assets = ROOT / 'assets/icon'
    icon(1024).convert('RGB').save(assets / 'icon_flat.png')
    icon(1024, transparent=True).save(assets / 'icon_foreground.png')
    Image.new('RGB', (1024, 1024), BACKGROUND).save(assets / 'icon_background.png')
    patterns = [
        'android/app/src/main/res/mipmap-*/vespertv_launcher.png',
        'ios/Runner/Assets.xcassets/AppIcon.appiconset/*.png',
        'macos/Runner/Assets.xcassets/AppIcon.appiconset/*.png',
        'web/icons/*.png', 'web/favicon.png',
    ]
    for pattern in patterns:
        for path in ROOT.glob(pattern):
            with Image.open(path) as old:
                size = old.width
            icon(size).convert('RGB').save(path)
    for path in ROOT.glob('android/app/src/main/res/drawable-*/ic_launcher_*.png'):
        with Image.open(path) as old:
            size = old.width
        layer = (icon(size, transparent=True) if 'foreground' in path.name else
                 Image.new('RGB', (size, size), BACKGROUND))
        layer.save(path)
    icon(256).save(ROOT / 'windows/runner/resources/app_icon.ico',
                   sizes=[(s, s) for s in (16, 24, 32, 48, 64, 128, 256)])


if __name__ == '__main__':
    main()

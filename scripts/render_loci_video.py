#!/usr/bin/env python3
from __future__ import annotations

import math
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "dist" / "video"
FRAME_DIR = OUT_DIR / "frames"
OUTPUT = OUT_DIR / "loci-product-demo.mp4"
ICON_PATH = ROOT / "Sources" / "Loci" / "Resources" / "AppIcon.png"

W, H = 1920, 1080
FPS = 24
DURATION = 18
FRAME_COUNT = FPS * DURATION

FONT_REGULAR = "/System/Library/Fonts/SFNS.ttf"
FONT_FALLBACK = "/System/Library/Fonts/Supplemental/Arial.ttf"


def font(size: int, fallback: str = FONT_FALLBACK) -> ImageFont.FreeTypeFont:
    for path in (FONT_REGULAR, fallback):
        try:
            return ImageFont.truetype(path, size=size)
        except OSError:
            continue
    return ImageFont.load_default(size=size)


FONTS = {
    "hero": font(116),
    "title": font(72),
    "subtitle": font(38),
    "body": font(30),
    "small": font(24),
    "tiny": font(18),
}


def clamp(value: float, lower: float = 0.0, upper: float = 1.0) -> float:
    return min(upper, max(lower, value))


def smoothstep(value: float) -> float:
    value = clamp(value)
    return value * value * (3 - 2 * value)


def scene_progress(t: float, start: float, end: float) -> float:
    return smoothstep((t - start) / (end - start))


def text_size(draw: ImageDraw.ImageDraw, text: str, fnt: ImageFont.FreeTypeFont) -> tuple[int, int]:
    box = draw.textbbox((0, 0), text, font=fnt)
    return box[2] - box[0], box[3] - box[1]


def draw_text(
    draw: ImageDraw.ImageDraw,
    xy: tuple[float, float],
    text: str,
    fnt: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int, int],
    anchor: str = "la",
) -> None:
    draw.text(xy, text, font=fnt, fill=fill, anchor=anchor)


def draw_centered(
    draw: ImageDraw.ImageDraw,
    y: float,
    text: str,
    fnt: ImageFont.FreeTypeFont,
    fill: tuple[int, int, int, int],
) -> None:
    tw, _ = text_size(draw, text, fnt)
    draw.text(((W - tw) / 2, y), text, font=fnt, fill=fill)


def add_shadowed_round_rect(
    image: Image.Image,
    rect: tuple[float, float, float, float],
    radius: int,
    fill: tuple[int, int, int, int],
    outline: tuple[int, int, int, int] | None = None,
    shadow_alpha: int = 28,
    shadow_radius: int = 22,
    shadow_offset: tuple[int, int] = (0, 12),
) -> None:
    draw = ImageDraw.Draw(image)
    sx0, sy0, sx1, sy1 = rect
    ox, oy = shadow_offset
    if shadow_alpha > 0:
        draw.rounded_rectangle(
            (sx0 + ox, sy0 + oy, sx1 + ox, sy1 + oy),
            radius=radius,
            fill=(0, 0, 0, max(1, shadow_alpha // 2)),
        )
        if shadow_radius > 10:
            draw.rounded_rectangle(
                (sx0 + ox * 0.35, sy0 + oy * 0.35, sx1 + ox * 0.35, sy1 + oy * 0.35),
                radius=radius,
                fill=(0, 0, 0, max(1, shadow_alpha // 4)),
            )
    draw.rounded_rectangle(rect, radius=radius, fill=fill, outline=outline, width=1 if outline else 0)


def make_background() -> Image.Image:
    image = Image.new("RGBA", (W, H))
    pix = image.load()
    top = (250, 250, 248)
    bottom = (238, 241, 242)
    for y in range(H):
        mix = y / max(1, H - 1)
        row = tuple(int(top[i] * (1 - mix) + bottom[i] * mix) for i in range(3))
        for x in range(W):
            pix[x, y] = (*row, 255)
    return image


BASE_BG = make_background()
ICON = Image.open(ICON_PATH).convert("RGBA")


def draw_space_dots(draw: ImageDraw.ImageDraw, t: float, alpha: int = 6) -> None:
    spacing = 82
    drift_x = (t * 18) % spacing
    drift_y = (t * 10) % spacing
    for x in range(-spacing, W + spacing, spacing):
        for y in range(-spacing, H + spacing, spacing):
            px = x + drift_x
            py = y + drift_y
            draw.ellipse((px - 1.1, py - 1.1, px + 1.1, py + 1.1), fill=(0, 0, 0, alpha))


def draw_thumbnail_grid(image: Image.Image, t: float, origin: tuple[int, int], scale: float = 1.0) -> None:
    draw = ImageDraw.Draw(image)
    ox, oy = origin
    colors = [
        (225, 232, 238),
        (241, 232, 219),
        (226, 238, 226),
        (239, 226, 223),
        (228, 226, 239),
        (232, 236, 230),
    ]
    for i in range(18):
        col = i % 6
        row = i // 6
        w = 116 * scale
        h = (92 + (i % 3) * 18) * scale
        gap = 18 * scale
        x = ox + col * (w + gap)
        y = oy + row * (132 * scale) + math.sin(t * 1.4 + i) * 3
        radius = int(14 * scale)
        fill = (*colors[i % len(colors)], 255)
        add_shadowed_round_rect(
            image,
            (x, y, x + w, y + h),
            radius,
            fill,
            outline=(0, 0, 0, 14),
            shadow_alpha=12,
            shadow_radius=8,
            shadow_offset=(0, 4),
        )
        draw.rounded_rectangle(
            (x + 10 * scale, y + 10 * scale, x + w - 10 * scale, y + h * 0.58),
            radius=max(4, int(8 * scale)),
            fill=(255, 255, 255, 118),
        )
        draw.line(
            (x + 14 * scale, y + h - 24 * scale, x + w - 18 * scale, y + h - 24 * scale),
            fill=(0, 0, 0, 28),
            width=max(1, int(2 * scale)),
        )


def draw_infinity_space(image: Image.Image, t: float) -> None:
    draw = ImageDraw.Draw(image)
    center = (W * 0.63, H * 0.52)
    groups = [
        ("Files", -330, -190, (233, 239, 247)),
        ("Web", 320, -190, (247, 232, 229)),
        ("Links", 320, 190, (231, 244, 233)),
        ("Memory", -330, 190, (246, 238, 225)),
    ]
    zoom = 0.86 + scene_progress(t, 9.0, 13.0) * 0.22
    for label, gx, gy, color in groups:
        x = center[0] + gx * zoom
        y = center[1] + gy * zoom
        rect = (x - 176, y - 108, x + 176, y + 108)
        add_shadowed_round_rect(
            image,
            rect,
            26,
            (*color, 178),
            outline=(0, 0, 0, 18),
            shadow_alpha=18,
            shadow_radius=18,
            shadow_offset=(0, 8),
        )
        draw.text((x - 136, y - 88), label, font=FONTS["tiny"], fill=(0, 0, 0, 112))
        for i in range(10):
            angle = i * 0.82 + t * 0.16
            px = x + math.cos(angle) * (34 + (i % 3) * 23)
            py = y + math.sin(angle * 1.3) * (22 + (i % 2) * 18)
            draw.rounded_rectangle(
                (px - 30, py - 21, px + 30, py + 21),
                radius=8,
                fill=(255, 255, 255, 210),
                outline=(0, 0, 0, 18),
                width=1,
            )


def draw_ui_shell(image: Image.Image, t: float) -> None:
    add_shadowed_round_rect(
        image,
        (250, 206, 1670, 884),
        30,
        (255, 255, 255, 255),
        outline=(0, 0, 0, 18),
        shadow_alpha=30,
        shadow_radius=36,
        shadow_offset=(0, 20),
    )
    draw = ImageDraw.Draw(image)
    draw.rounded_rectangle((286, 248, 476, 842), radius=22, fill=(246, 247, 246, 255))
    for idx, label in enumerate(["Inbox", "All", "X Sync", "Files", "Infinity"]):
        y = 302 + idx * 68
        selected = label == "Infinity" and t > 8.6
        fill = (35, 35, 35, 22 if selected else 0)
        draw.rounded_rectangle((314, y - 22, 448, y + 22), radius=12, fill=fill)
        draw.text((334, y - 12), label, font=FONTS["tiny"], fill=(0, 0, 0, 170 if selected else 96))
    draw.rounded_rectangle((520, 250, 1608, 304), radius=18, fill=(247, 248, 247, 255), outline=(0, 0, 0, 12))
    draw.text((552, 266), "Search your visual memory", font=FONTS["tiny"], fill=(0, 0, 0, 72))


def draw_frame(frame_index: int) -> Image.Image:
    t = frame_index / FPS
    image = BASE_BG.copy()
    draw = ImageDraw.Draw(image)
    draw_space_dots(draw, t)

    intro = 1 - scene_progress(t, 2.3, 3.1)
    shell_in = scene_progress(t, 2.0, 3.4)
    if intro > 0.02:
        icon_size = int(186 + scene_progress(t, 0.0, 1.5) * 10)
        icon = ICON.resize((icon_size, icon_size), Image.Resampling.LANCZOS)
        image.alpha_composite(icon, ((W - icon_size) // 2, 258))
        draw_centered(draw, 494, "Loci", FONTS["hero"], (18, 18, 18, int(245 * intro)))
        draw_centered(draw, 632, "A calm, local-first library for visual memory.", FONTS["subtitle"], (18, 18, 18, int(150 * intro)))

    if shell_in > 0.02:
        y_shift = (1 - shell_in) * 70
        shell = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        draw_ui_shell(shell, t)
        if t < 8.5:
            draw_thumbnail_grid(shell, t, (555, 352), 1.02)
        else:
            draw_infinity_space(shell, t)
        shell = shell.transform(shell.size, Image.Transform.AFFINE, (1, 0, 0, 0, 1, y_shift), resample=Image.Resampling.BICUBIC)
        image.alpha_composite(shell)

    if 3.1 <= t < 7.1:
        p = scene_progress(t, 3.1, 3.8)
        draw.text((250, 110 - (1 - p) * 24), "Drop, search, rediscover.", font=FONTS["title"], fill=(20, 20, 20, int(235 * p)))
        draw.text((254, 190 - (1 - p) * 20), "Files, screenshots, links and X bookmarks live in one fast visual surface.", font=FONTS["body"], fill=(20, 20, 20, int(128 * p)))

    if 7.1 <= t < 12.8:
        p = scene_progress(t, 7.1, 7.8)
        draw.text((250, 110 - (1 - p) * 24), "Grid / Canvas / Infinity", font=FONTS["title"], fill=(20, 20, 20, int(235 * p)))
        draw.text((254, 190 - (1 - p) * 20), "Move from a clean library to a spatial map without losing context.", font=FONTS["body"], fill=(20, 20, 20, int(128 * p)))

    if 12.8 <= t < 16.2:
        p = scene_progress(t, 12.8, 13.5)
        draw.text((250, 110 - (1 - p) * 24), "Smooth enough to think through.", font=FONTS["title"], fill=(20, 20, 20, int(235 * p)))
        draw.text((254, 190 - (1 - p) * 20), "Anchored zoom, native scrolling, and preview transitions that stay out of the way.", font=FONTS["body"], fill=(20, 20, 20, int(128 * p)))

    if t >= 16.2:
        p = scene_progress(t, 16.2, 16.8)
        fade = scene_progress(t, 17.4, 18.0)
        overlay = Image.new("RGBA", (W, H), (250, 250, 248, int(220 * p)))
        image.alpha_composite(overlay)
        icon_size = 132
        icon = ICON.resize((icon_size, icon_size), Image.Resampling.LANCZOS)
        image.alpha_composite(icon, (250, 332))
        draw.text((420, 342), "Loci", font=FONTS["title"], fill=(18, 18, 18, int(240 * p * (1 - fade * 0.35))))
        draw.text((424, 430), "Your visual memory, organized locally.", font=FONTS["body"], fill=(18, 18, 18, int(130 * p * (1 - fade * 0.35))))
        draw.rounded_rectangle((424, 502, 736, 560), radius=18, fill=(18, 18, 18, int(230 * p)))
        draw.text((462, 518), "Ready for GitHub", font=FONTS["small"], fill=(255, 255, 255, int(235 * p)))

    return image.convert("RGB")


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    if FRAME_DIR.exists():
        shutil.rmtree(FRAME_DIR)
    FRAME_DIR.mkdir(parents=True)

    for index in range(FRAME_COUNT):
        frame = draw_frame(index)
        frame.save(FRAME_DIR / f"frame_{index:04d}.png", optimize=False)

    cmd = [
        "ffmpeg",
        "-y",
        "-framerate",
        str(FPS),
        "-i",
        str(FRAME_DIR / "frame_%04d.png"),
        "-c:v",
        "libx264",
        "-preset",
        "medium",
        "-crf",
        "18",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        str(OUTPUT),
    ]
    subprocess.run(cmd, check=True)
    print(OUTPUT)


if __name__ == "__main__":
    main()

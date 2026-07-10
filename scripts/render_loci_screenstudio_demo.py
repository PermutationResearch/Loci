#!/usr/bin/env python3
from __future__ import annotations

import math
import shutil
import subprocess
import textwrap
from dataclasses import dataclass
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
VIDEO_DIR = ROOT / "dist" / "video"
INPUT = VIDEO_DIR / "loci-demo-app-capture.mp4"
OUTPUT = VIDEO_DIR / "loci-screenstudio-demo.mp4"
OUTPUT_4K = VIDEO_DIR / "loci-screenstudio-demo-4k.mp4"
THUMB = VIDEO_DIR / "loci-screenstudio-demo-thumb.png"
WORK = VIDEO_DIR / "screenstudio-work"
RAW_FRAMES = WORK / "raw"
OUT_FRAMES = WORK / "frames"

W, H = 1920, 1080
FPS = 60
MENU_H = 34
DOCK_H = 86
WALLPAPER_SOURCE = Path("/System/Library/Desktop Pictures/.wallpapers/Sonoma Horizon/Sonoma Horizon.heic")
WALLPAPER_CACHE = Path("/private/tmp/loci-sonoma-wallpaper.png")
LOCAL_WALLPAPER = VIDEO_DIR / "sonoma-horizon-wallpaper.png"
FFMPEG = shutil.which("ffmpeg") or "/opt/homebrew/bin/ffmpeg"

FONT_REGULAR = "/System/Library/Fonts/SFNS.ttf"
FONT_FALLBACK = "/System/Library/Fonts/Supplemental/Arial.ttf"


def font(size: int) -> ImageFont.FreeTypeFont:
    for path in (FONT_REGULAR, FONT_FALLBACK):
        try:
            return ImageFont.truetype(path, size=size)
        except OSError:
            continue
    return ImageFont.load_default(size=size)


F = {
    "menu": font(15),
    "tiny": font(18),
    "body": font(20),
    "title": font(31),
}


def run(command: list[str]) -> None:
    subprocess.run(command, cwd=ROOT, check=True)


def ffmpeg_command(*args: str) -> list[str]:
    return [FFMPEG, *args]


def clamp(value: float, low: float = 0.0, high: float = 1.0) -> float:
    return min(high, max(low, value))


def smoothstep(value: float) -> float:
    value = clamp(value)
    return value * value * (3 - 2 * value)


def ease(value: float) -> float:
    value = clamp(value)
    if value < 0.5:
        return 4 * value * value * value
    return 1 - pow(-2 * value + 2, 3) / 2


def smootherstep(value: float) -> float:
    value = clamp(value)
    return value * value * value * (value * (value * 6 - 15) + 10)


def lerp(a: float, b: float, p: float) -> float:
    return a + (b - a) * p


def rounded_rect(
    draw: ImageDraw.ImageDraw,
    rect: tuple[float, float, float, float],
    radius: int,
    fill: tuple[int, int, int, int],
    outline: tuple[int, int, int, int] | None = None,
    width: int = 1,
) -> None:
    draw.rounded_rectangle(rect, radius=radius, fill=fill, outline=outline, width=width)


def cover_resize(image: Image.Image, size: tuple[int, int]) -> Image.Image:
    target_w, target_h = size
    src_w, src_h = image.size
    scale = max(target_w / src_w, target_h / src_h)
    resized = image.resize((int(src_w * scale), int(src_h * scale)), Image.Resampling.LANCZOS)
    left = (resized.width - target_w) // 2
    top = (resized.height - target_h) // 2
    return resized.crop((left, top, left + target_w, top + target_h))


def generated_wallpaper() -> Image.Image:
    img = Image.new("RGBA", (W, H), (12, 18, 28, 255))
    pix = img.load()
    stops = ((14, 24, 38), (41, 91, 116), (237, 178, 130), (245, 236, 214))
    for y in range(H):
        ny = y / H
        for x in range(W):
            nx = x / W
            wave = math.sin((nx * 2.2 + ny * 1.6) * math.tau) * 0.035
            p = clamp(ny + wave)
            if p < 0.42:
                q = p / 0.42
                a, b = stops[0], stops[1]
            elif p < 0.72:
                q = (p - 0.42) / 0.30
                a, b = stops[1], stops[2]
            else:
                q = (p - 0.72) / 0.28
                a, b = stops[2], stops[3]
            glow = math.exp(-((nx - 0.68) ** 2 + (ny - 0.25) ** 2) / 0.08)
            color = [int(a[i] * (1 - q) + b[i] * q + glow * 28) for i in range(3)]
            pix[x, y] = tuple(max(0, min(255, c)) for c in color) + (255,)
    return img.filter(ImageFilter.GaussianBlur(0.6))


def make_wallpaper() -> Image.Image:
    if LOCAL_WALLPAPER.exists():
        image = Image.open(LOCAL_WALLPAPER).convert("RGBA")
        image = cover_resize(image, (W, H))
        veil = Image.new("RGBA", (W, H), (255, 255, 255, 34))
        image.alpha_composite(veil)
        return image.filter(ImageFilter.GaussianBlur(0.18))

    if WALLPAPER_SOURCE.exists():
        try:
            run(["sips", "-s", "format", "png", str(WALLPAPER_SOURCE), "--out", str(WALLPAPER_CACHE)])
            image = Image.open(WALLPAPER_CACHE).convert("RGBA")
            image = cover_resize(image, (W, H))
            veil = Image.new("RGBA", (W, H), (255, 255, 255, 38))
            image.alpha_composite(veil)
            return image.filter(ImageFilter.GaussianBlur(0.25))
        except Exception:
            pass
    return generated_wallpaper()


WALLPAPER = make_wallpaper()


def draw_menu_bar(img: Image.Image) -> None:
    draw = ImageDraw.Draw(img)
    draw.rectangle((0, 0, W, MENU_H), fill=(255, 255, 255, 190))
    draw.text((22, 9), "Loci", font=F["menu"], fill=(20, 22, 24, 220))
    x = 72
    for item in ["File", "Edit", "View", "Window", "Help"]:
        draw.text((x, 9), item, font=F["menu"], fill=(20, 22, 24, 150))
        x += 54 if item != "Window" else 78
    draw.text((W - 230, 9), "Tue Jul 7 8:34 PM", font=F["menu"], fill=(20, 22, 24, 142))


def draw_dock(img: Image.Image) -> None:
    draw = ImageDraw.Draw(img)
    dock_w = 520
    dock_x = (W - dock_w) // 2
    dock_y = H - DOCK_H + 18
    rounded_rect(draw, (dock_x, dock_y, dock_x + dock_w, dock_y + 58), 22, (255, 255, 255, 178), (255, 255, 255, 210))
    colors = [
        (64, 145, 238),
        (42, 42, 45),
        (246, 87, 74),
        (255, 191, 72),
        (50, 180, 112),
        (117, 96, 230),
        (245, 245, 246),
        (31, 31, 33),
    ]
    for i, color in enumerate(colors):
        x = dock_x + 28 + i * 58
        y = dock_y + 9
        rounded_rect(draw, (x, y, x + 42, y + 42), 11, (*color, 238), (0, 0, 0, 24))
        if i == 1:
            draw.text((x + 11, y + 7), "L", font=F["body"], fill=(255, 255, 255, 236))


def app_crop(frame: Image.Image) -> Image.Image:
    crop = frame.crop((144, 0, 1776, 1080))
    return crop.filter(ImageFilter.UnsharpMask(radius=1.0, percent=105, threshold=2))


def camera_pose(t: float) -> tuple[float, float, float]:
    keyframes = [
        (0.0, 1.00, 960, 540),
        (1.55, 1.00, 960, 540),
        (2.25, 1.035, 960, 515),
        (3.25, 1.085, 990, 505),
        (4.65, 1.075, 990, 520),
        (5.35, 1.015, 960, 540),
        (5.90, 1.00, 960, 560),
        (6.85, 1.075, 1100, 715),
        (7.65, 1.075, 1110, 720),
        (8.20, 1.02, 990, 560),
        (8.85, 1.10, 960, 500),
        (10.05, 1.10, 960, 500),
        (10.75, 1.04, 960, 560),
        (11.40, 1.02, 1000, 570),
        (12.20, 1.085, 1125, 735),
        (14.0, 1.065, 1120, 700),
    ]
    for idx in range(len(keyframes) - 1):
        a = keyframes[idx]
        b = keyframes[idx + 1]
        if a[0] <= t <= b[0]:
            p = smootherstep((t - a[0]) / (b[0] - a[0]))
            return lerp(a[1], b[1], p), lerp(a[2], b[2], p), lerp(a[3], b[3], p)
    return keyframes[-1][1], keyframes[-1][2], keyframes[-1][3]


@dataclass(frozen=True)
class Callout:
    start: float
    end: float
    title: str
    body: str
    x: int
    y: int
    width: int


CALLOUTS = [
    Callout(0.28, 2.35, "Loci", "A local-first visual library for references, files, and saved web material.", 300, 908, 590),
    Callout(2.35, 5.05, "Preview in place", "Open websites and images without losing the grid around them.", 300, 908, 530),
    Callout(5.05, 7.75, "Arrange on Canvas", "Turn saved material into a spatial board for visual thinking.", 300, 908, 520),
    Callout(7.75, 10.85, "Explore Infinity", "Move through clusters without leaving the library context.", 300, 908, 510),
    Callout(10.85, 14.0, "Search X bookmarks", "Filter imported posts visually, then open the source when needed.", 300, 908, 530),
]


def callout_for_time(t: float) -> Callout | None:
    for callout in CALLOUTS:
        if callout.start <= t <= callout.end:
            return callout
    return None


def wrapped_text(text: str, width: int = 50) -> str:
    return "\n".join(textwrap.wrap(text, width=width, max_lines=2, placeholder="..."))


def draw_callout(img: Image.Image, t: float) -> None:
    current = callout_for_time(t)
    if current is None:
        return
    alpha = min(smoothstep((t - current.start) / 0.24), smoothstep((current.end - t) / 0.24))
    if alpha <= 0.01:
        return

    w = current.width
    x = current.x
    y = current.y
    body = wrapped_text(current.body, width=max(36, int(w / 10)))
    body_lines = body.count("\n") + 1
    h = 104 + max(0, body_lines - 1) * 22

    shadow = Image.new("RGBA", img.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    rounded_rect(sd, (x + 4, y + 10, x + w + 4, y + h + 10), 18, (0, 0, 0, int(30 * alpha)))
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(16)))

    draw = ImageDraw.Draw(img)
    rounded_rect(draw, (x, y, x + w, y + h), 17, (255, 255, 255, int(242 * alpha)), (255, 255, 255, int(185 * alpha)))
    draw.text((x + 24, y + 18), current.title, font=F["title"], fill=(15, 17, 20, int(232 * alpha)))
    draw.multiline_text((x + 26, y + 63), body, font=F["body"], fill=(15, 17, 20, int(154 * alpha)), spacing=4)


def cursor_position(t: float, window_rect: tuple[int, int, int, int]) -> tuple[float, float, float]:
    wx, wy, ww, wh = window_rect
    points = [
        (0.0, 0.62, 0.42),
        (2.15, 0.44, 0.35),
        (5.2, 0.50, 0.94),
        (7.8, 0.66, 0.93),
        (11.7, 0.79, 0.94),
        (14.0, 0.82, 0.90),
    ]
    for idx in range(len(points) - 1):
        a = points[idx]
        b = points[idx + 1]
        if a[0] <= t <= b[0]:
            p = smootherstep((t - a[0]) / (b[0] - a[0]))
            return wx + lerp(a[1], b[1], p) * ww, wy + lerp(a[2], b[2], p) * wh, 1.0
    return wx + 0.8 * ww, wy + 0.9 * wh, 1.0


def camera_transform(t: float) -> tuple[float, int, int]:
    zoom, fx, fy = camera_pose(t)
    if zoom <= 1.001:
        return 1.0, 0, 0
    crop_w = W / zoom
    crop_h = H / zoom
    left = int(clamp(fx - crop_w / 2, 0, W - crop_w))
    top = int(clamp(fy - crop_h / 2, 0, H - crop_h))
    return zoom, left, top


def transform_point(point: tuple[float, float], transform: tuple[float, int, int]) -> tuple[float, float]:
    zoom, left, top = transform
    return (point[0] - left) * zoom, (point[1] - top) * zoom


def draw_cursor(img: Image.Image, x: float, y: float, alpha: float = 1.0) -> None:
    draw = ImageDraw.Draw(img)
    a = int(235 * alpha)
    points = [
        (x, y),
        (x + 2, y + 29),
        (x + 9, y + 22),
        (x + 14, y + 35),
        (x + 20, y + 32),
        (x + 15, y + 20),
        (x + 25, y + 20),
    ]
    shadow = [(px + 2, py + 3) for px, py in points]
    draw.polygon(shadow, fill=(0, 0, 0, int(52 * alpha)))
    draw.polygon(points, fill=(255, 255, 255, a), outline=(18, 18, 20, int(190 * alpha)))


def compose_base_scene(app_frame: Image.Image) -> tuple[Image.Image, tuple[int, int, int, int]]:
    scene = WALLPAPER.copy()
    draw = ImageDraw.Draw(scene)
    draw_menu_bar(scene)

    outer = (250, 74, 1670, 900)
    ox0, oy0, ox1, oy1 = outer
    ow = ox1 - ox0

    shadow = Image.new("RGBA", scene.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    rounded_rect(sd, (ox0 + 10, oy0 + 20, ox1 + 10, oy1 + 20), 30, (0, 0, 0, 66))
    scene.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(26)))

    rounded_rect(draw, outer, 24, (250, 250, 250, 248), (255, 255, 255, 170))
    draw.rectangle((ox0 + 1, oy0 + 42, ox1 - 1, oy1 - 1), fill=(255, 255, 255, 255))
    for i, color in enumerate([(255, 95, 86), (255, 189, 46), (39, 201, 63)]):
        draw.ellipse((ox0 + 21 + i * 22, oy0 + 15, ox0 + 33 + i * 22, oy0 + 27), fill=(*color, 245))
    draw.text((ox0 + ow / 2 - 18, oy0 + 14), "Loci", font=F["tiny"], fill=(20, 20, 22, 120))

    content_rect = (ox0 + 1, oy0 + 42, ox1 - 1, oy1 - 1)
    cx0, cy0, cx1, cy1 = content_rect
    app = app_crop(app_frame).resize((cx1 - cx0, cy1 - cy0), Image.Resampling.LANCZOS)
    scene.alpha_composite(app, (cx0, cy0))
    return scene, content_rect


def apply_camera(scene: Image.Image, transform: tuple[float, int, int]) -> Image.Image:
    zoom, left, top = transform
    if zoom <= 1.001:
        return scene
    crop_w = int(W / zoom)
    crop_h = int(H / zoom)
    crop = scene.crop((left, top, left + crop_w, top + crop_h))
    return crop.resize((W, H), Image.Resampling.LANCZOS)


def compose_scene(app_frame: Image.Image, t: float) -> Image.Image:
    scene, content_rect = compose_base_scene(app_frame)
    transform = camera_transform(t)
    cursor_x, cursor_y, cursor_alpha = cursor_position(t, content_rect)
    scene = apply_camera(scene, transform)
    cursor_x, cursor_y = transform_point((cursor_x, cursor_y), transform)
    draw_cursor(scene, cursor_x, cursor_y, cursor_alpha)
    draw_callout(scene, t)
    return scene


def main() -> None:
    if not INPUT.exists():
        raise SystemExit(f"Missing input capture: {INPUT}")
    if WORK.exists():
        shutil.rmtree(WORK)
    RAW_FRAMES.mkdir(parents=True)
    OUT_FRAMES.mkdir(parents=True)

    run(ffmpeg_command(
        "-y",
        "-i",
        str(INPUT),
        "-vf",
        f"fps={FPS}",
        str(RAW_FRAMES / "frame_%04d.png"),
    ))

    frames = sorted(RAW_FRAMES.glob("frame_*.png"))
    if not frames:
        raise SystemExit("No frames extracted from app capture")

    for index, frame_path in enumerate(frames):
        t = index / FPS
        frame = Image.open(frame_path).convert("RGBA")
        composed = compose_scene(frame, t)
        composed.save(OUT_FRAMES / f"frame_{index + 1:04d}.png")
        if index == min(len(frames) - 1, FPS * 6):
            composed.save(THUMB)

    duration = f"{len(frames) / FPS:.3f}"
    shutil.rmtree(RAW_FRAMES)

    run(ffmpeg_command(
        "-y",
        "-framerate",
        str(FPS),
        "-i",
        str(OUT_FRAMES / "frame_%04d.png"),
        "-f",
        "lavfi",
        "-t",
        duration,
        "-i",
        "anullsrc=channel_layout=stereo:sample_rate=48000",
        "-vf",
        "sidedata=delete:type=ICC_PROFILE,format=yuv420p",
        "-c:v",
        "libx264",
        "-preset",
        "slow",
        "-profile:v",
        "baseline",
        "-level:v",
        "4.2",
        "-crf",
        "8",
        "-bf",
        "0",
        "-refs",
        "1",
        "-r",
        str(FPS),
        "-video_track_timescale",
        "600",
        "-pix_fmt",
        "yuv420p",
        "-color_primaries",
        "bt709",
        "-color_trc",
        "bt709",
        "-colorspace",
        "bt709",
        "-c:a",
        "aac",
        "-shortest",
        "-movflags",
        "+faststart",
        str(OUTPUT),
    ))

    run(ffmpeg_command(
        "-y",
        "-framerate",
        str(FPS),
        "-i",
        str(OUT_FRAMES / "frame_%04d.png"),
        "-vf",
        "sidedata=delete:type=ICC_PROFILE,scale=3840:2160:flags=lanczos,format=yuv420p",
        "-c:v",
        "libx264",
        "-preset",
        "slow",
        "-profile:v",
        "high",
        "-level:v",
        "5.2",
        "-crf",
        "8",
        "-r",
        str(FPS),
        "-video_track_timescale",
        "600",
        "-pix_fmt",
        "yuv420p",
        "-color_primaries",
        "bt709",
        "-color_trc",
        "bt709",
        "-colorspace",
        "bt709",
        "-movflags",
        "+faststart",
        str(OUTPUT_4K),
    ))
    print(f"Wrote {OUTPUT}")
    print(f"Wrote {OUTPUT_4K}")
    print(f"Wrote {THUMB}")


if __name__ == "__main__":
    main()

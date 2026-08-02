#!/usr/bin/env python3
"""
Split a sprite sheet of cartoon avatars into individual transparent PNGs.

Usage:
  python3 extract_avatars.py <input.png> <output_dir> [--expected N]

Requires: Pillow (PIL)
"""

from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path

from PIL import Image

PAPER = (243, 231, 209)
PAPER_THRESH = 55
DARK_THRESH = 55
MIN_COMPONENT_AREA = 80
PAD = 2


def is_paper(c: tuple[int, ...]) -> bool:
    r, g, b = c[:3]
    dr, dg, db = r - PAPER[0], g - PAPER[1], b - PAPER[2]
    if (dr * dr + dg * dg + db * db) ** 0.5 <= PAPER_THRESH:
        return True
    # Nearby light warm neutrals (anti-aliased paper)
    if (
        r > 220
        and g > 210
        and b > 185
        and abs(r - g) < 25
        and (r - b) > 15
        and (g - b) > 5
    ):
        return True
    return False


def is_dark_frame(c: tuple[int, ...]) -> bool:
    r, g, b = c[:3]
    return (
        max(r, g, b) < DARK_THRESH
        and abs(r - g) < 12
        and abs(g - b) < 12
        and abs(r - b) < 12
    )


def neighbors(x: int, y: int, w: int, h: int):
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dx == 0 and dy == 0:
                continue
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h:
                yield nx, ny


def key_background(img: Image.Image) -> Image.Image:
    """Remove cream paper + dark border; keep avatar shapes with soft edges."""
    w, h = img.size
    pix = img.load()
    out = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    out_pix = out.load()

    for y in range(h):
        for x in range(w):
            c = pix[x, y]
            r, g, b, _ = c
            if is_paper(c) or is_dark_frame(c):
                continue
            dr, dg, db = r - PAPER[0], g - PAPER[1], b - PAPER[2]
            d = (dr * dr + dg * dg + db * db) ** 0.5
            if d < PAPER_THRESH + 25:
                a = int(max(0, min(255, (d - (PAPER_THRESH - 15)) / 40 * 255)))
            else:
                a = 255
            if a < 8:
                continue
            out_pix[x, y] = (r, g, b, a)
    return out


def find_components(out: Image.Image, min_area: int = MIN_COMPONENT_AREA) -> list[dict]:
    w, h = out.size
    out_pix = out.load()
    visited = [[False] * w for _ in range(h)]
    components: list[dict] = []

    for y in range(h):
        for x in range(w):
            if visited[y][x] or out_pix[x, y][3] < 32:
                continue
            q = deque([(x, y)])
            visited[y][x] = True
            pixels: list[tuple[int, int]] = []
            minx = maxx = x
            miny = maxy = y
            while q:
                cx, cy = q.popleft()
                pixels.append((cx, cy))
                if cx < minx:
                    minx = cx
                if cx > maxx:
                    maxx = cx
                if cy < miny:
                    miny = cy
                if cy > maxy:
                    maxy = cy
                for nx, ny in neighbors(cx, cy, w, h):
                    if not visited[ny][nx] and out_pix[nx, ny][3] >= 32:
                        visited[ny][nx] = True
                        q.append((nx, ny))
            area = len(pixels)
            if area < min_area:
                continue
            components.append(
                {
                    "bbox": (minx, miny, maxx, maxy),
                    "pixels": pixels,
                    "area": area,
                    "cx": (minx + maxx) / 2,
                    "cy": (miny + maxy) / 2,
                }
            )
    return components


def order_reading(components: list[dict], expected: int | None) -> list[dict]:
    components = sorted(components, key=lambda c: -c["area"])
    if expected is not None:
        components = components[:expected]

    # Cluster into rows by y-center gaps, then left-to-right within each row.
    components = sorted(components, key=lambda c: c["cy"])
    if not components:
        return []

    rows: list[list[dict]] = [[components[0]]]
    # Gap threshold: half the median avatar height, or a fraction of image span
    heights = [c["bbox"][3] - c["bbox"][1] for c in components]
    heights.sort()
    median_h = heights[len(heights) // 2]
    row_gap = max(20, median_h * 0.55)

    for comp in components[1:]:
        if abs(comp["cy"] - rows[-1][-1]["cy"]) > row_gap:
            rows.append([comp])
        else:
            rows[-1].append(comp)

    ordered: list[dict] = []
    for row in rows:
        ordered.extend(sorted(row, key=lambda c: c["cx"]))
    return ordered


def export_components(out: Image.Image, components: list[dict], out_dir: Path) -> list[Path]:
    w, h = out.size
    out_pix = out.load()
    out_dir.mkdir(parents=True, exist_ok=True)
    saved: list[Path] = []

    for i, comp in enumerate(components, 1):
        minx, miny, maxx, maxy = comp["bbox"]
        minx = max(0, minx - PAD)
        miny = max(0, miny - PAD)
        maxx = min(w - 1, maxx + PAD)
        maxy = min(h - 1, maxy + PAD)
        cw, ch = maxx - minx + 1, maxy - miny + 1
        crop = Image.new("RGBA", (cw, ch), (0, 0, 0, 0))
        cp = crop.load()

        comp_set = set(comp["pixels"])
        halo = set(comp_set)
        for px, py in comp["pixels"]:
            for nx, ny in neighbors(px, py, w, h):
                if minx <= nx <= maxx and miny <= ny <= maxy:
                    halo.add((nx, ny))

        for px, py in halo:
            a = out_pix[px, py][3]
            if a == 0:
                continue
            cp[px - minx, py - miny] = out_pix[px, py]

        path = out_dir / f"avatar_{i:02d}.png"
        crop.save(path, "PNG")
        saved.append(path)
        print(f"saved {path.name} {crop.size} area={comp['area']}")

    return saved


def extract(input_path: Path, output_dir: Path, expected: int | None = None) -> list[Path]:
    img = Image.open(input_path).convert("RGBA")
    keyed = key_background(img)
    components = find_components(keyed)
    print(f"found {len(components)} components in {input_path.name} ({img.size[0]}x{img.size[1]})")
    ordered = order_reading(components, expected)
    print(f"exporting {len(ordered)} avatars -> {output_dir}")
    return export_components(keyed, ordered, output_dir)


def main() -> None:
    parser = argparse.ArgumentParser(description="Extract avatar sprites to transparent PNGs")
    parser.add_argument("input", type=Path, help="Source sprite sheet PNG")
    parser.add_argument("output_dir", type=Path, help="Folder for avatar_XX.png files")
    parser.add_argument(
        "--expected",
        type=int,
        default=None,
        help="Keep only the N largest components (e.g. 20)",
    )
    args = parser.parse_args()
    saved = extract(args.input, args.output_dir, args.expected)
    print(f"done: {len(saved)} files")


if __name__ == "__main__":
    main()

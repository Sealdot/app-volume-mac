#!/usr/bin/env python3
"""Export iOS artwork plus a legacy macOS iconset and ICNS file."""

from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw


ICON_EXPORTS = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="Source PNG used to create the icon")
    parser.add_argument(
        "--resources-dir",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "Resources",
    )
    parser.add_argument(
        "--macos-mask-template",
        type=Path,
        help="PNG whose alpha channel defines the legacy macOS icon silhouette",
    )
    return parser.parse_args()


def fallback_macos_mask(size: int) -> Image.Image:
    scale = 4
    mask = Image.new("L", (size * scale, size * scale), 0)
    inset = 12 * scale
    ImageDraw.Draw(mask).rounded_rectangle(
        (inset, inset, size * scale - inset - 1, size * scale - inset - 1),
        radius=218 * scale,
        fill=255,
    )
    return mask.resize((size, size), Image.Resampling.LANCZOS)


def macos_mask(template_path: Path, size: int) -> Image.Image:
    if template_path.exists():
        template = Image.open(template_path).convert("RGBA")
        alpha = template.getchannel("A")
        if alpha.getextrema() != (255, 255):
            return alpha.resize((size, size), Image.Resampling.LANCZOS)
    return fallback_macos_mask(size)


def main() -> None:
    args = parse_args()
    source = Image.open(args.source)
    srgb_profile = source.info.get("icc_profile")
    if not srgb_profile:
        raise ValueError("The iOS artwork source must contain an ICC profile")
    if "A" in source.getbands() and source.getchannel("A").getextrema() != (255, 255):
        raise ValueError("The iOS artwork source must be fully opaque")
    ios_master = source.convert("RGB").resize((1024, 1024), Image.Resampling.LANCZOS)

    resources_dir = args.resources_dir.resolve()
    iconset_dir = resources_dir / "AppIcon.iconset"
    resources_dir.mkdir(parents=True, exist_ok=True)
    iconset_dir.mkdir(parents=True, exist_ok=True)

    mask_template = args.macos_mask_template or resources_dir / "AppIcon.png"
    macos_master = ios_master.convert("RGBA")
    macos_master.putalpha(macos_mask(mask_template, 1024))

    ios_master.save(
        resources_dir / "AppIcon-iOS.png",
        optimize=True,
        icc_profile=srgb_profile,
    )
    macos_master.save(
        resources_dir / "AppIcon.png",
        optimize=True,
        icc_profile=srgb_profile,
    )
    for filename, size in ICON_EXPORTS.items():
        icon = macos_master.resize((size, size), Image.Resampling.LANCZOS)
        icon.save(iconset_dir / filename, optimize=True, icc_profile=srgb_profile)

    subprocess.run(
        [
            "/usr/bin/iconutil",
            "-c",
            "icns",
            "-o",
            str(resources_dir / "AppIcon.icns"),
            str(iconset_dir),
        ],
        check=True,
    )


if __name__ == "__main__":
    main()

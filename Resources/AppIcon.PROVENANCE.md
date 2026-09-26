# VolumeGuard App Icon Provenance

The icon was redesigned on 2026-08-23 with the built-in Codex ImageGen workflow,
using the previous VolumeGuard icon as the identity reference. The final direction
keeps the blue/cyan palette, shield, speaker, and exactly three sound-wave bands,
while simplifying the voxel construction for stronger recognition at small sizes.

The production artwork follows Apple's current app-icon guidance: a centered,
simple focal point on a square 1024×1024 layer, with no alpha and no pre-rendered
corner mask. `Resources/AppIcon-iOS.png` is this unmasked, opaque sRGB artwork.
The repository's legacy macOS packaging still consumes an ICNS file, so
`scripts/export-app-icon.py` applies a separate alpha silhouette only to the
macOS PNG/iconset/ICNS exports.

Apple guidance consulted:

- https://developer.apple.com/design/human-interface-guidelines/app-icons

The visual direction references the broad block-building-game aesthetic requested
for the project. It intentionally avoids Minecraft logos, named characters, grass
or dirt blocks, and copied game textures.

## Final generation prompt

```text
Use case: logo-brand
Asset type: production iOS app icon artwork master, 1024 x 1024
Primary request: Redesign the provided VolumeGuard icon to follow Apple iOS app icon design principles while keeping its original voxel/block pixel-art personality.
Input image: Image 1 is the identity and style reference. Preserve the blue/cyan palette and the recognizable meaning: one protective shield containing one speaker and exactly three sound-wave bands.
Canvas and mask: create a completely square, edge-to-edge, opaque 1024x1024 artwork layer. NO transparency. NO baked-in rounded corners. NO black or empty corner areas. NO outer drop shadow around an icon tile. The operating system will apply the rounded-rectangle mask.
Design: embrace simplicity and use one strong centered focal point. Simplify the current artwork substantially: use fewer, larger voxel blocks; a bolder shield silhouette; a clearer speaker; exactly three broad sound-wave bands. Keep all primary content centered and comfortably inside the central safe area so system corner masking never clips it.
Style/medium: refined premium voxel/pixel-block illustration with crisp stepped geometry, limited controlled depth, subtle material shading, and clean Apple-platform polish. The background may use a restrained full-bleed blue-to-cyan gradient made from large tonal block facets, but it must remain quiet and secondary.
Composition: symmetrical, front-facing, strong at small sizes, high contrast between the ice-white symbol and cobalt background, no tiny tiles or fussy detail.
Color palette: bright cyan and sky blue at the top, saturated cobalt/deep blue toward the bottom, ice-white foreground blocks, restrained navy shadows.
Constraints: square opaque RGB artwork; single focal point; exactly one shield, one speaker, exactly three wave bands; no text; no letters; no watermark; no pre-rounded border or mask; no foreground elements near corners.
Avoid: Minecraft logo or copied game assets, grass/dirt textures, characters, glossy glass UI, thin outlines, excessive beveling, excessive 3D perspective, photorealism, checkerboard transparency, black corners, icon-within-an-icon framing.
```

The generated RGB artwork was normalized to 1024×1024, tagged as sRGB, and saved
as the iOS artwork master. The same source was then deterministically resized into
the complete legacy macOS iconset and compiled into `AppIcon.icns`.

To regenerate the exports, install Pillow for Python 3 and run the
`reexportCommand` in `Resources/AppIcon.manifest.json`. The script retains the
source ICC profile so repeated exports produce the recorded SHA-256 hashes.

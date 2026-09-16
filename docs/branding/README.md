# GarminDesk — app branding

The **Activity watch** concept was selected on September 16, 2026: a round case, watch hands, and a mint activity ring. The color original was created with the built-in ImageGen tool. Packaging preserves the selected artwork and tile geometry, normalizes its opacity, and generates the required resolutions. The original PNG remains unchanged.

The selected color icon remains in 0.3.0. The app moves to a regular window and Dock icon; the menu-bar assets and build 8 checks below remain historical documentation of the 0.2.0 design.

## Ready-to-use assets

- [App icon — ICNS](../../Resources/AppIcon.icns): 10 representations for standard and Retina displays.
- [Icon — 1024×1024 PNG](../../Resources/Branding/AppIcon-1024.png): for the project page and related materials.
- [Source PNG](../../Resources/Branding/AppIcon-source.png): an exact copy of the selected concept, 1254×1254.
- [Menu-bar symbol — PDF](../../Resources/Branding/MenuBarTemplate.pdf): a monochrome vector symbol.
- [Symbol — 18×18 PNG](../../Resources/Branding/MenuBarTemplate.png) and [36×36 Retina PNG](../../Resources/Branding/MenuBarTemplate@2x.png).

The menu-bar symbol simplifies the design to a round watch case, short straps, and hands. The decorative activity ring and depth are omitted for legibility at small sizes. Shared geometry is in `Sources/Shared/GarminDeskBrandGeometry.swift`; it is used in the menu bar, panel and widget headings, and PNG/PDF export. The app draws the symbol as a vector NSImage with `isTemplate = true`, so macOS chooses a color suitable for the menu-bar background.

To regenerate assets:

```bash
bash scripts/generate-icon.sh
```

Set `GARMIN_SDK_PATH` if a specific compatible SDK is needed. The generator uses system AppKit/CoreGraphics and iconutil; it does not call an image generation service. `scripts/build-app.sh` runs it before building. All ten PNGs are saved in `build/AppIcon.iconset`; the finished ICNS is copied into the app. Generating assets does not install the app.

## Integration validation

**0.2.0, build 8, arm64** was built using SDK 26.5. App and extension compilation, bundle structure verification, and ad-hoc signature checks passed. The ICNS inside the app matches the new resource byte for byte. The color source PNG matches the selected concept; the largest export is 1024×1024, and the icon and both menu-bar PNGs contain an alpha channel. Native rendering checked the monochrome symbol at 13, 16, 18, and 24 pt. Installation and live widget-gallery checks were not performed for this build.

## Icon opacity correction in the 0.5.0 candidate

A later macOS 26.6.2 check reproduced a small green watch tile inside an extra gray system plate. The gray plate was absent from the source artwork and ICNS. Inspection found that most pixels in the supposedly solid tile had alpha 252–253 rather than 255, and faint nearly transparent pixels extended outside the visible tile.

The icon generator now normalizes alpha values of at least 248 to 255 and removes exterior noise at alpha 8 or below before creating the size variants. Premultiplied color channels are adjusted with alpha so the selected artwork retains its appearance. The original source, watch design, palette, tile bounds, and transparent rounded corners are preserved. No additional crop, enlargement, background plate, or new logo is introduced.

macOS icon-service renders of isolated local app fixtures reproduced the gray plate with the original ICNS at 32 and 256 pt and removed it with the normalized ICNS. The watch consequently appears larger at those same system icon sizes. The original already rendered without the plate at 48 and 64 pt; the corrected icon preserves that behavior. Comparisons were captured at all four sizes. Both fixtures used distinct diagnostic bundle identifiers, and neither was launched or installed. This verifies the local icon rendering change; it does not establish live widget-gallery refresh after an ordinary upgrade, which still requires the [upgrade validation](../widget-upgrade-validation.md).

Apple's [app icon guidance](https://developer.apple.com/design/human-interface-guidelines/app-icons/) requires opaque background artwork for the modern layered format. This change keeps the existing ICNS distribution and corrects its unintended translucency; it does not claim a layered Icon Composer asset or new appearance variants.

## Watch concepts

- [Pulse watch](concepts/05-watch-pulse.png): a rectangular case with a pulse line on the dial.
- [Activity watch](concepts/06-watch-orbit.png): the selected original.

## Initial directions

- [Pulse](concepts/01-pulse.png)
- [Orbit](concepts/02-orbit.png)
- [Cards](concepts/03-cards.png): an early sketch; the outer edge needs cleanup before use.

## Formats

1. A color app icon in ICNS. The current build uses 16, 32, 128, 256, and 512 pt, each at 1× and 2×. The largest representation is 1024×1024 px.
2. A simplified monochrome menu-bar symbol without a square background, adapted for small sizes. The system colors the template image to match its appearance.
3. A PNG of the selected icon for the README and project page.

The current implementation does not require a separate logo for each system-widget size. Early concepts are retained as history; the build uses the files under “Ready-to-use assets.”

Technical requirements: [Apple — Icon Set Type](https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/IconSetType.html), [Apple — NSImage.isTemplate](https://developer.apple.com/documentation/appkit/nsimage/istemplate).

## Exact prompts

Mode: built-in ImageGen, without a CLI/API fallback. Each concept was generated with a separate request. Actual output dimensions may differ from those requested in the prompt.

### 01-pulse — Pulse

```text
Use case: logo-brand.
Asset type: polished standalone macOS application icon concept for GarminDesk, a native desktop companion that displays fitness, recovery, sleep and activity metrics from Garmin Connect.
Format: one square 1024 x 1024 icon asset, front-on orthographic view. A single centered macOS rounded-square tile occupies about 88 percent of the canvas width and height; truly transparent background outside the tile, including corners. This is the actual asset, not a presentation board or a screenshot.
Visual language: refined, simple, confident native desktop utility. Established project palette is deep forest green #143E36, mint #A5DFC0 and warm ivory #F6F2DE. Subtle smooth material shading and a fine highlight on the tile edge; generous space, bold silhouette and excellent small-size legibility. No detailed textures, tiny decorative lines, extraneous indicator dots or elaborate glow. Symbol should occupy about 58 percent of tile width.
Constraints: no written text, no letters used as captions, no words, no labels, no watermark, no numbers. Invent an original independent app identity, with no Garmin triangle or Garmin wordmark. No Apple logo, no product screenshots, no physical devices, no multiple icons, no perspective.
Concept: PULSE. Deep forest-green rounded-square tile. One warm ivory, substantial continuous waveform with round caps, a short flat lead-in, a clean high ascent followed by a low trough and recovery, then a short flat lead-out. The balanced waveform reads as energy and daily health in a single memorable gesture. Restrained shallow relief with no other symbol. Smooth considered geometry, calm elegant finish.
```

### 02-orbit — Orbit

```text
Use case: logo-brand.
Asset type: polished standalone macOS application icon concept for GarminDesk, a native desktop companion that displays fitness, recovery, sleep and activity metrics from Garmin Connect.
Format: one square 1024 x 1024 icon asset, front-on orthographic view. A single centered macOS rounded-square tile occupies about 88 percent of the canvas width and height; truly transparent background outside the tile, including corners. This is the actual asset, not a presentation board or a screenshot.
Visual language: refined, simple, confident native desktop utility. Established project palette is deep forest green #143E36, mint #A5DFC0 and warm ivory #F6F2DE. Subtle smooth material shading and a fine highlight on the tile edge; generous space, bold silhouette and excellent small-size legibility. No detailed textures, tiny decorative lines, extraneous indicator dots or elaborate glow. Symbol should occupy about 58 percent of tile width.
Constraints: no written text, no letters used as captions, no words, no labels, no watermark, no numbers. Invent an original independent app identity, with no Garmin triangle or Garmin wordmark. No Apple logo, no product screenshots, no physical devices, no multiple icons, no perspective.
Concept: ORBIT. Deep forest-green rounded-square tile. One bold almost-circular mint arc with a precisely shaped opening on the right; its lower right endpoint turns inward into a short horizontal warm-ivory arm, subtly evoking an original geometric G and a daily progress gauge at the same time. A single integrated mark, visually centered. Bold sculpted band with subtle mint-to-ivory material shift, clean geometry, large empty center. No heart, waveform, arrows or extra rings. A distinctive restrained premium app icon.
```

### 03-cards — Cards

```text
Use case: logo-brand.
Asset type: polished standalone macOS application icon concept for GarminDesk, a native desktop companion that displays fitness, recovery, sleep and activity metrics from Garmin Connect.
Format: one square 1024 x 1024 icon asset, front-on orthographic view. A single centered macOS rounded-square tile occupies about 88 percent of the canvas width and height; truly transparent background outside the tile, including corners. This is the actual asset, not a presentation board or a screenshot.
Visual language: refined, simple, confident native desktop utility. Established project palette is deep forest green #143E36, mint #A5DFC0 and warm ivory #F6F2DE. Subtle smooth material shading and a fine highlight on the tile edge; generous space, bold silhouette and excellent small-size legibility. No detailed textures, tiny decorative lines, extraneous indicator dots or elaborate glow. Symbol should occupy about 58 percent of tile width.
Constraints: no written text, no letters used as captions, no words, no labels, no watermark, no numbers. Invent an original independent app identity, with no Garmin triangle or Garmin wordmark. No Apple logo, no product screenshots, no physical devices, no multiple icons, no perspective.
Concept: CARDS. Warm ivory rounded-square tile with a gentle porcelain surface. A bold centered abstract widget arrangement made of exactly three deep forest-green rounded shapes: one tall capsule-like rectangular card on the left and two short horizontal rounded rectangular cards stacked on the right, with generous even gaps. The upper right card is mint-green. The silhouette suggests a compact desktop health dashboard, but contains no chart, data, glyphs or interior details. Subtle shallow dimensional relief. Ultra simple, balanced and recognizable.
```

### 05-watch-pulse — Pulse watch

```text
Use case: logo-brand.
Asset type: standalone macOS app icon concept for GarminDesk, an independent native utility showing fitness-watch health and activity data on the Mac.
Primary request: make SPORTS WRISTWATCHES the unmistakable main subject of the app icon.
Format: one square high-resolution app icon PNG, front-on orthographic view. A single smoothly rounded square macOS tile occupies approximately 86 percent of the canvas, centered. True transparent alpha outside the tile, clean antialiased perimeter, absolutely no stray particles, fringe or shadow outside the tile. No mockup, no presentation board, no text.
Style: striking premium native macOS icon; strong simple carefully proportioned forms, precise smooth edges, restrained depth, sophisticated soft material lighting with no heavy glossy reflections. The watch silhouette including visible short top and bottom straps occupies approximately 70 percent of the tile height; generously spaced and legible at small size. Use original watch design with no brand insignia. The whole icon reads as a wristwatch first, metrics second.
Established palette: deep forest-green tile #143E36 with a very subtle gradient to #0C2826, warm ivory #F6F2DE watch details, fresh mint #A5DFC0 accent.
Constraints: one watch only, no hand, wrist or person, no physical-device photograph, no Garmin wordmark or Garmin triangle, no Apple logo, no lettering or numbers, no wordmarks, no caption, no watermark, no secondary symbols around the watch, no fine tick marks, no tiny screws, no surface grain or busy detail.
Design A — PULSE WATCH: a compact upright rectangular sports wristwatch with very softly rounded rectangular case, substantial warm-ivory bezel and short broad mint-green strap sections extending vertically above and below, both fully visible. Dark forest dial inset within the bezel. On the dial, one single thick warm-ivory energy waveform with rounded ends: brief horizontal line, high peak, low trough, small recovery and horizontal end. Exactly one small simple ivory crown at right mid-case, integrated in the silhouette. No other controls or dial elements. Beautiful balanced geometric icon, not realistic hardware. The watch is centered and the pulse is uncluttered and fully inside its dark dial.
```

### 06-watch-orbit — Activity watch

```text
Use case: logo-brand.
Asset type: standalone macOS app icon concept for GarminDesk, an independent native utility showing fitness-watch health and activity data on the Mac.
Primary request: make SPORTS WRISTWATCHES the unmistakable main subject of the app icon.
Format: one square high-resolution app icon PNG, front-on orthographic view. A single smoothly rounded square macOS tile occupies approximately 86 percent of the canvas, centered. True transparent alpha outside the tile, clean antialiased perimeter, absolutely no stray particles, fringe or shadow outside the tile. No mockup, no presentation board, no text.
Style: striking premium native macOS icon; strong simple carefully proportioned forms, precise smooth edges, restrained depth, sophisticated soft material lighting with no heavy glossy reflections. The watch silhouette including visible short top and bottom straps occupies approximately 70 percent of the tile height; generously spaced and legible at small size. Use original watch design with no brand insignia. The whole icon reads as a wristwatch first, metrics second.
Established palette: deep forest-green tile #143E36 with a very subtle gradient to #0C2826, warm ivory #F6F2DE watch details, fresh mint #A5DFC0 accent.
Constraints: one watch only, no hand, wrist or person, no physical-device photograph, no Garmin wordmark or Garmin triangle, no Apple logo, no lettering or numbers, no wordmarks, no caption, no watermark, no secondary symbols around the watch, no fine tick marks, no tiny screws, no surface grain or busy detail.
Design B — ACTIVITY WATCH: a bold round sports wristwatch with a substantial warm-ivory circular case, clean dark forest-green circular dial and short broad mint-green strap sections visible above and below. The dial has a single thick mint progress arc sweeping about three quarters of a circle, generous spacing from the bezel. Inside the arc are only two substantial ivory analog watch hands at approximately 10:10 and a tiny central hub. No numerals and no tick marks. One discreet simple ivory side crown. Symmetrical sporty silhouette with clearly defined lugs, watch centered. The circular watch and broken activity ring create a distinctive compact athletic app symbol. Keep all shapes broad and restrained.
```

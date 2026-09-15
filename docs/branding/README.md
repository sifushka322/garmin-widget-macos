# GarminDesk — оформление приложения

16 сентября 2026 выбран вариант **«Часы — активность»**: круглый корпус, стрелки и мятное кольцо активности. Цветной оригинал создан встроенным ImageGen; при упаковке его рисунок сохраняется, меняется только разрешение.

Для 0.3.0 сохраняется выбранная цветная иконка. Приложение переходит к обычному окну и Dock; описанные ниже ресурсы строки меню и проверки build 8 остаются историей оформления 0.2.0.

## Готовые ресурсы

- [Иконка приложения — ICNS](../../Resources/AppIcon.icns): 10 представлений для обычных и Retina-экранов.
- [Иконка — PNG 1024×1024](../../Resources/Branding/AppIcon-1024.png): для страницы проекта и материалов.
- [Исходный PNG](../../Resources/Branding/AppIcon-source.png): точная копия выбранного варианта, 1254×1254.
- [Знак строки меню — PDF](../../Resources/Branding/MenuBarTemplate.pdf): векторный монохромный знак.
- [Знак — PNG 18×18](../../Resources/Branding/MenuBarTemplate.png) и [36×36 для Retina](../../Resources/Branding/MenuBarTemplate@2x.png).

Знак строки меню упрощён до корпуса круглых часов, коротких ремешков и стрелок. Декоративное кольцо активности и объём опущены для читаемости в малом размере. Общая геометрия находится в `Sources/Shared/GarminDeskBrandGeometry.swift`; она используется в строке меню, заголовках панели и виджетов, а также при экспорте PNG/PDF. Приложение рисует знак векторно через NSImage с `isTemplate = true`, поэтому macOS подбирает цвет для фона строки меню.

Повторная генерация:

```bash
bash scripts/generate-icon.sh
```

При необходимости можно указать совместимый SDK через `GARMIN_SDK_PATH`. Генератор использует системные AppKit/CoreGraphics и iconutil, не обращается к сервису генерации изображений. `scripts/build-app.sh` запускает его перед сборкой. Все десять PNG сохраняются в `build/AppIcon.iconset`; готовый ICNS копируется в приложение. Генерация ресурсов сама по себе не устанавливает приложение.

## Проверка подключения

Собрана версия **0.2.0, build 8, arm64** с SDK 26.5. Компиляция приложения и расширения, проверка структуры bundle и ad-hoc подписи прошли. ICNS внутри приложения побайтно совпадает с новым ресурсом. Исходный цветной PNG совпадает с выбранной концепцией; максимальный экспорт — 1024×1024, иконка и оба меню-PNG содержат alpha-канал. Монохромный знак проверен нативным рендерингом в размерах 13, 16, 18 и 24 pt. Установка и проверка живой галереи виджетов для этой сборки не выполнялись.

## Варианты с часами

- [Часы — пульс](concepts/05-watch-pulse.png): прямоугольный корпус, линия пульса на экране.
- [Часы — активность](concepts/06-watch-orbit.png): выбранный оригинал.

## Первые направления

- [Пульс](concepts/01-pulse.png)
- [Орбита](concepts/02-orbit.png)
- [Карточки](concepts/03-cards.png): ранний эскиз; наружный край нуждается в очистке перед применением.

## Форматы

1. Цветная иконка приложения в ICNS; текущая сборка использует 16, 32, 128, 256 и 512 pt, каждый в 1× и 2×. Крупнейшее представление — 1024×1024 px.
2. Упрощённый монохромный знак без квадратного фона для строки меню, адаптированный к маленькому размеру. Система окрашивает template image в соответствии с оформлением.
3. PNG выбранной иконки для README и страницы проекта.

Отдельный логотип для каждого размера системного виджета текущей реализации не требуется. Ранние концепции сохранены для истории; в сборке используются ресурсы раздела «Готовые ресурсы».

Источники технических требований: [Apple — Icon Set Type](https://developer.apple.com/library/archive/documentation/Xcode/Reference/xcode_ref-Asset_Catalog_Format/IconSetType.html), [Apple — NSImage.isTemplate](https://developer.apple.com/documentation/appkit/nsimage/istemplate).

## Точные промпты

Режим: встроенный ImageGen, без CLI/API fallback. Каждый вариант создавался отдельным запросом. Размеры фактического результата могут отличаться от размера, указанного в промпте.

### 01-pulse — Пульс

```text
Use case: logo-brand.
Asset type: polished standalone macOS application icon concept for GarminDesk, a native desktop companion that displays fitness, recovery, sleep and activity metrics from Garmin Connect.
Format: one square 1024 x 1024 icon asset, front-on orthographic view. A single centered macOS rounded-square tile occupies about 88 percent of the canvas width and height; truly transparent background outside the tile, including corners. This is the actual asset, not a presentation board or a screenshot.
Visual language: refined, simple, confident native desktop utility. Established project palette is deep forest green #143E36, mint #A5DFC0 and warm ivory #F6F2DE. Subtle smooth material shading and a fine highlight on the tile edge; generous space, bold silhouette and excellent small-size legibility. No detailed textures, tiny decorative lines, extraneous indicator dots or elaborate glow. Symbol should occupy about 58 percent of tile width.
Constraints: no written text, no letters used as captions, no words, no labels, no watermark, no numbers. Invent an original independent app identity, with no Garmin triangle or Garmin wordmark. No Apple logo, no product screenshots, no physical devices, no multiple icons, no perspective.
Concept: PULSE. Deep forest-green rounded-square tile. One warm ivory, substantial continuous waveform with round caps, a short flat lead-in, a clean high ascent followed by a low trough and recovery, then a short flat lead-out. The balanced waveform reads as energy and daily health in a single memorable gesture. Restrained shallow relief with no other symbol. Smooth considered geometry, calm elegant finish.
```

### 02-orbit — Орбита

```text
Use case: logo-brand.
Asset type: polished standalone macOS application icon concept for GarminDesk, a native desktop companion that displays fitness, recovery, sleep and activity metrics from Garmin Connect.
Format: one square 1024 x 1024 icon asset, front-on orthographic view. A single centered macOS rounded-square tile occupies about 88 percent of the canvas width and height; truly transparent background outside the tile, including corners. This is the actual asset, not a presentation board or a screenshot.
Visual language: refined, simple, confident native desktop utility. Established project palette is deep forest green #143E36, mint #A5DFC0 and warm ivory #F6F2DE. Subtle smooth material shading and a fine highlight on the tile edge; generous space, bold silhouette and excellent small-size legibility. No detailed textures, tiny decorative lines, extraneous indicator dots or elaborate glow. Symbol should occupy about 58 percent of tile width.
Constraints: no written text, no letters used as captions, no words, no labels, no watermark, no numbers. Invent an original independent app identity, with no Garmin triangle or Garmin wordmark. No Apple logo, no product screenshots, no physical devices, no multiple icons, no perspective.
Concept: ORBIT. Deep forest-green rounded-square tile. One bold almost-circular mint arc with a precisely shaped opening on the right; its lower right endpoint turns inward into a short horizontal warm-ivory arm, subtly evoking an original geometric G and a daily progress gauge at the same time. A single integrated mark, visually centered. Bold sculpted band with subtle mint-to-ivory material shift, clean geometry, large empty center. No heart, waveform, arrows or extra rings. A distinctive restrained premium app icon.
```

### 03-cards — Карточки

```text
Use case: logo-brand.
Asset type: polished standalone macOS application icon concept for GarminDesk, a native desktop companion that displays fitness, recovery, sleep and activity metrics from Garmin Connect.
Format: one square 1024 x 1024 icon asset, front-on orthographic view. A single centered macOS rounded-square tile occupies about 88 percent of the canvas width and height; truly transparent background outside the tile, including corners. This is the actual asset, not a presentation board or a screenshot.
Visual language: refined, simple, confident native desktop utility. Established project palette is deep forest green #143E36, mint #A5DFC0 and warm ivory #F6F2DE. Subtle smooth material shading and a fine highlight on the tile edge; generous space, bold silhouette and excellent small-size legibility. No detailed textures, tiny decorative lines, extraneous indicator dots or elaborate glow. Symbol should occupy about 58 percent of tile width.
Constraints: no written text, no letters used as captions, no words, no labels, no watermark, no numbers. Invent an original independent app identity, with no Garmin triangle or Garmin wordmark. No Apple logo, no product screenshots, no physical devices, no multiple icons, no perspective.
Concept: CARDS. Warm ivory rounded-square tile with a gentle porcelain surface. A bold centered abstract widget arrangement made of exactly three deep forest-green rounded shapes: one tall capsule-like rectangular card on the left and two short horizontal rounded rectangular cards stacked on the right, with generous even gaps. The upper right card is mint-green. The silhouette suggests a compact desktop health dashboard, but contains no chart, data, glyphs or interior details. Subtle shallow dimensional relief. Ultra simple, balanced and recognizable.
```

### 05-watch-pulse — Часы — пульс

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

### 06-watch-orbit — Часы — активность

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

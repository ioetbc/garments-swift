# Garms — Canvas research

Research date: 24 September 2026. Companion to [PRODUCT_SPEC.md](PRODUCT_SPEC.md).

This document records the canvas architecture discussion and relevant Apple documentation. The UIKit canvas embedded in SwiftUI is the agreed direction. Implementation details below are proposals to validate, not completed code or measured performance.

## 1. Architecture

Build a small, independent editing engine hosted inside a custom UIKit view. SwiftUI handles toolbars, search, product sheets, and surrounding navigation.

```text
SwiftUI: CanvasScreen
  ├─ Toolbar, search, product sheets
  └─ CanvasHost: UIViewRepresentable
       └─ GarmsCanvasView: UIView
            ├─ World layer
            │    └─ Visible sticker layers
            └─ Overlay view
                 └─ Selection, handles, outfit labels
```

Apple documents the building blocks rather than this exact editor. Camera behaviour, gesture ownership, grouping, and hit testing require our own application logic.

Keep storage local initially: JSON records and separate image files, without authentication or a backend. Persistence stays outside the rendering loop.

## 2. SwiftUI–UIKit boundary

Use `UIViewRepresentable`:

- `makeUIView` creates the canvas and interaction machinery.
- `updateUIView` applies external changes such as imports or toolbar actions without rebuilding the scene.
- A `Coordinator` forwards selection changes and completed edits to the app.
- Cleanup cancels view-specific work and stops active display links.

During dragging, UIKit updates temporary interaction state and layers directly. Avoid routing every finger movement through SwiftUI state and back into UIKit. Completed operations update the document and trigger autosave; selection changes update surrounding controls. External updates must not overwrite active gestures with stale geometry.

SwiftUI controls the hosted view's layout. Apply camera transforms to internal layers, not the represented view's frame or transform.

Reference: [UIViewRepresentable](https://developer.apple.com/documentation/SwiftUI/UIViewRepresentable/).

## 3. Rendering with Core Animation

Give each visible sticker a `CALayer` whose contents are a prepared cutout image. Moving changes position, resizing changes bounds or transform, and stacking changes layer ordering. Reuse image contents throughout these operations.

Selection handles and labels live in a screen-space overlay. Their positions follow world geometry, but their text and touch targets stay usable at different zoom levels.

Disable implicit animations during direct manipulation so the sticker follows the finger immediately:

```swift
CATransaction.begin()
CATransaction.setDisableActions(true)
stickerLayer.position = newPosition
CATransaction.commit()
```

Use intentional animations for grouping previews and navigation. Do not enable rasterization or expensive shadows indiscriminately; measure their effects with real content.

Layers are a strong starting point, not a performance guarantee. Transparent overlap, decoded image memory, and visible layer count still matter.

References:

- [CALayer](https://developer.apple.com/documentation/quartzcore/calayer)
- [Core Animation Basics](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html)
- [CATransaction](https://developer.apple.com/documentation/quartzcore/catransaction)
- [Improving Animation Performance](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/ImprovingAnimationPerformance/ImprovingAnimationPerformance.html)

## 4. Camera and coordinates

Persist sticker positions and dimensions in world coordinates. Keep the camera separate:

```swift
struct CanvasCamera {
    var center: CGPoint // World position at the viewport's center
    var zoom: CGFloat
}
```

For a canvas without rotation:

```text
screenPoint = viewportCenter + (worldPoint − cameraCenter) × zoom
worldPoint  = cameraCenter + (screenPoint − viewportCenter) ÷ zoom
```

These are vector equations; the Swift implementation supplies component-wise operations.

- Panning changes camera position.
- Moving changes sticker position.
- Resizing changes sticker dimensions.
- Canvas zoom never changes saved sticker dimensions.
- Pinch zoom preserves the world point beneath the pinch midpoint, including movement of that midpoint.

Use affine transforms and inverse transforms consistently for rendering, hit testing, and selection geometry. Clamp zoom to a supported nonzero range.

Near-infinite space does not require a giant view or bitmap. Render only around the camera. If distant coordinates cause precision problems, render relative to a nearby origin while preserving stable document coordinates.

A custom camera is preferred over adapting finite `UIScrollView` content bounds because of the app's specific gesture rules. This means we also own momentum, zoom anchoring, and navigation behaviour.

Reference: [CGAffineTransform](https://developer.apple.com/documentation/corefoundation/cgaffinetransform).

## 5. Gesture ownership

Attach a small set of recognizers to the canvas rather than separate recognizers to every sticker: `UITapGestureRecognizer`, `UIPanGestureRecognizer`, `UIPinchGestureRecognizer`, and `UILongPressGestureRecognizer`.

An interaction controller owns explicit states: idle, pan camera, move sticker, resize sticker, move group, resize group, and detach member.

| Gesture starts on | Proposed behaviour |
| --- | --- |
| Empty space | Drag pans canvas |
| Sticker | Drag moves sticker |
| Selected sticker, with both pinch touches inside its selection bounds | Pinch resizes sticker |
| Elsewhere | Pinch zooms canvas |
| Selection corner | Drag resizes with proportions preserved |
| Outfit label | Drag moves group |
| Individual group member, with long press | Begin detachment |

Record the target and starting geometry at gesture start. Derive updates from that baseline to avoid accumulated rounding errors. Keep ownership stable unless an explicitly supported transition occurs.

Prototype a second finger arriving during dragging. A transition into a compatible pinch should capture fresh baseline geometry so the sticker does not jump. Never accidentally apply canvas zoom and sticker resize to the same pinch.

Cancellation restores the edit's starting state. Completion commits one operation.

References:

- [Supporting gesture interaction](https://developer.apple.com/documentation/uikit/supporting-gesture-interaction-in-your-apps)
- [Filtering incoming touches](https://developer.apple.com/documentation/uikit/uigesturerecognizerdelegate/gesturerecognizer%28_%3Ashouldreceive%3A%29-16fuh)
- [Preferring one gesture over another](https://developer.apple.com/documentation/uikit/preferring-one-gesture-over-another)
- [Simultaneous recognition](https://developer.apple.com/documentation/uikit/uigesturerecognizerdelegate/gesturerecognizer%28_%3Ashouldrecognizesimultaneouslywith%3A%29)
- [require(toFail:)](https://developer.apple.com/documentation/uikit/uigesturerecognizer/require%28tofail%3A%29)

## 6. Hit testing and magnetic groups

Custom hit testing checks overlay controls first, then queries nearby sticker bounds, examines candidates from front to back, and samples a cached low-resolution alpha mask in image coordinates. Transparent image margins let touches reach objects underneath. Standard rectangular layer hit testing does not provide this behaviour.

Tune alpha thresholds and touch tolerance so thin garment details remain easy to select. Trim transparent margins during asset preparation to improve selection, scaling, grouping, and size matching for alternatives.

For magnetic grouping, compare resized bounds with nearby placements, preview the join, and commit membership on release. Store membership explicitly rather than continuously inferring it from proximity.

Express proximity thresholds in screen points and convert to world units using zoom. Use a larger detach threshold than attach threshold to reduce unstable joining. Exact thresholds remain prototype decisions.

Group movement preserves relative geometry and stacking. Scaling transforms member positions around a shared pivot and scales dimensions uniformly. Group membership need not dictate the layer hierarchy; preserve the product spec's global stacking behaviour.

## 7. Performance design

| Mechanism | Purpose |
| --- | --- |
| Visible-region queries | Materialise layers only in or near the viewport |
| Spatial index | Find visible objects and grouping neighbours efficiently |
| Multiple image resolutions | Match decoded image size to displayed pixel size |
| Shared asset cache | Duplicate placements reuse image data |
| Background image preparation | Keep file reads, decoding, and cutouts outside gesture handling |
| Incremental updates | Update changed layers and affected overlays |
| Bounded cache and cancellable requests | Prevent memory accumulation during long pans |

Choose a simple spatial index after profiling representative layouts. Its query interface should serve visibility, hit testing, and grouping.

Use Image I/O thumbnail generation for downsampling. A sticker displayed at 150 points wide on a 3× display needs approximately 450 pixels of width at that moment, rather than a decoded 4,000-pixel original. Use resolution tiers and avoid swapping images for tiny zoom changes. Cancel obsolete requests and validate asset identity before applying asynchronous results to reused layers.

Image preparation must execute outside the main actor; creating an asynchronous task alone does not ensure expensive synchronous work leaves it. Apply UIKit and visible-layer updates on the main actor.

Zooming far out can make the entire board visible. Culling alone cannot solve this workload. Validate minimum zoom, image tiers, and practical visible density before promising capacity. Overview simplification is an option if measurements justify it.

For momentum, `CADisplayLink` can advance the camera using elapsed time. Run it only while motion or another active animation requires updates, then stop it.

References:

- [CGImageSourceCreateThumbnailAtIndex](https://developer.apple.com/documentation/imageio/cgimagesourcecreatethumbnailatindex%28_%3A_%3A_%3A%29)
- [kCGImageSourceThumbnailMaxPixelSize](https://developer.apple.com/documentation/imageio/kcgimagesourcethumbnailmaxpixelsize)
- [CADisplayLink](https://developer.apple.com/documentation/quartzcore/cadisplaylink)
- [Understand and eliminate hangs](https://developer.apple.com/videos/play/wwdc2021/10258/)

## 8. Components, undo, and persistence

| Component | Responsibility |
| --- | --- |
| `CanvasDocument` | Placements, groups, stacking order |
| `CanvasCamera` | Coordinate conversion and viewport state |
| `CanvasInteractionController` | Gesture ownership and temporary edits |
| `CanvasRenderer` | Visible layers and overlays |
| `CanvasAssetStore` | Image variants, preparation, caching |
| `CanvasHistory` | Undoable operations |

Layers project document and interaction state; they are not the source of truth. Products remain separate records referenced by placement IDs' product references.

One completed drag creates one move operation. Undo reverses the whole drag. Apply this pattern to resize, grouping, replacement, duplication, and deletion. Document geometry should be testable without a view hierarchy.

Autosave completed edits through a serialised JSON store using atomic snapshots. Do not write JSON every frame. Debounce camera persistence. Runtime JSON belongs in the writable app container; repository files can provide seed data.

## 9. Export and accessibility

Export groups by rendering saved geometry with full-resolution cutouts into a chosen output size, excluding editor overlays. Share composition calculations between screen rendering and export so results do not depend on viewport zoom or screen bounds.

Standalone layers do not automatically provide accessible controls. Expose stickers and outfits through `UIAccessibilityElement`, with meaningful labels and editing actions. Keep accessibility geometry aligned with the camera and provide controls alongside gestures.

Reference: [UIAccessibilityElement](https://developer.apple.com/documentation/uikit/uiaccessibilityelement).

## 10. Prototype and validation

Suggested build sequence:

1. Camera transforms, layers, pan, and anchored zoom with prepared cutouts.
2. Selection, alpha-aware hit testing, drag, resize, and cancellation.
3. Culling, image tiers, caching, and performance workloads.
4. Group previews, movement, scaling, and detachment.
5. Undo, JSON persistence, export, and accessible controls.

Benchmark physical devices with 100, 500, and 2,000 saved placements. These are proposed test workloads, not capacity promises. Include repeated assets, unique images, dense overlap, uncached panning, zooming out to show everything, continuous pinch, and concurrent import processing.

Measure hitching, input responsiveness, decoded-image memory, and whether memory settles after repeated navigation. Aim for smooth 60 Hz interaction and 120 Hz where supported. Validate on the oldest supported hardware; do not infer performance solely from the simulator or average frame rate.

Add focused correctness checks for coordinate round trips, pinch anchoring, group scaling, cancellation, and undo. Verify product sharing across duplicate placements and agreement between saved composition and export.

References:

- [Explore UI animation hitches and the render loop](https://developer.apple.com/videos/play/tech-talks/10855/)
- [Demystify and eliminate hitches in the render phase](https://developer.apple.com/videos/play/tech-talks/10857/)

## 11. Open decisions

- Minimum iOS version and iPhone/iPad scope; iOS 17+ was proposed for the wider app, not confirmed here.
- Pinch ownership and transitions when fingers are added or removed.
- Zoom limits, momentum, and fit-to-content behaviour.
- Group selection and detachment thresholds.
- Alpha hit-test tolerance for thin or irregular cutouts.
- Spatial index, cache budget, and image resolution tiers.
- Practical visible density and whether overview simplification is needed.
- How imports and external updates interact with active edits.

## 12. Suggested reading order

Start with [Core Animation Basics](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CoreAnimation_guide/CoreAnimationBasics/CoreAnimationBasics.html), then [Supporting gesture interaction](https://developer.apple.com/documentation/uikit/supporting-gesture-interaction-in-your-apps), then [the render-loop talk](https://developer.apple.com/videos/play/tech-talks/10855/). Together they explain rendering, interaction, and performance measurement. The archived Core Animation guide is useful for concepts; use API reference pages for implementation details.

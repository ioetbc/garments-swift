> Historical plan: the editor features below were superseded by the bare-bones canvas simplification. See CANVAS_IMPLEMENTATION_NOTES.md for current behavior.

# Garms canvas — single-agent implementation plan

## 1. Assignment and completion criteria

Implement a working native image canvas in the existing app, replacing the starter UI in `ios/Garms/App/ContentView.swift`. Work through this plan sequentially as one agent. Do not stop after scaffolding, and do not create parallel agent tasks.

Read `CANVAS_RESEARCH.md` and the canvas-related parts of `PRODUCT_SPEC.md` first. This plan resolves prototype implementation choices; its tuning constants are starting values, not measured performance claims.

Deliver a canvas that supports:

- Near-infinite navigation, camera panning, and pinch zoom anchored under the fingers.
- Adding bundled sample images, dragging placements, independent image resizing, and overlapping images.
- Tap selection with visible product information and actions.
- Predictable gesture ownership, including adding a second finger during a drag.
- Alpha-aware hit testing through transparent image regions.
- Live proximity and overlap detection, magnetic group previews, and committed groups.
- Group movement, proportional scaling, naming, and member detachment.
- Undo/redo, local layout persistence, fit-to-content, and accessible editing actions.
- Visibility culling, image resolution tiers, bounded image caching, and reproducible performance scenarios.
- Clean image export of a selected group.

Use hardcoded products and local sample images. Do not implement Photos access, network imports, background removal, classification, search, accounts, cloud sync, or shopping workflows. Position and proximity detection are geometry operations, not computer vision.

## 2. Repository baseline and constraints

At the time this plan was written:

- `ContentView.swift` contains the default globe and “Hello, world!” UI.
- `garment_swiftApp.swift` presents `ContentView` in a `WindowGroup`.
- The project is `ios/Garms.xcodeproj`; its app target is `Garms`.
- Deployment target is iOS 26.2, device families include iPhone and iPad, and the project uses a filesystem-synchronized source group.
- Swift default actor isolation is `MainActor`, with approachable concurrency enabled.
- There are no canvas components, clothing assets, or test targets yet.
- Existing repository files include staged user work. Preserve unrelated changes, project identifiers, signing settings, and user workspace state. Do not reset or overwrite them.

Recheck these facts before implementation. Keep the deployment target as configured. Do not add third-party dependencies. Use SwiftUI for the app shell and UIKit/Core Animation for the canvas.

## 3. Architecture and suggested files

Place implementation files under `ios/Garms/Canvas/`. File names below are suggested; keep responsibilities distinct without building an unnecessary framework.

| File/component | Responsibility |
| --- | --- |
| `CanvasScreen.swift` | Toolbar, sample picker, compact selected-item card, group naming and sharing UI |
| `CanvasHost.swift` | `UIViewRepresentable`, coordinator, creation and cleanup of the UIKit canvas |
| `GarmsCanvasView.swift` | Root view, recognizers, layout, and connection between engine and renderer |
| `CanvasSession.swift` | Long-lived main-actor session; document, selection, commands, history and UI summaries |
| `CanvasDocument.swift` | Codable product references, placements, groups and explicit stacking order |
| `CanvasGeometry.swift` | World/screen conversion, anchored transforms, rectangle distance and group geometry |
| `CanvasCamera.swift` | Camera centre, zoom, viewport conversion and fit calculations |
| `CanvasInteractionController.swift` | Gesture ownership, edit snapshots, transitions, commit and cancellation |
| `CanvasRenderer.swift` | World layer, visible sticker layers, incremental reconciliation and layer reuse |
| `CanvasOverlayView.swift` | Screen-space selection outlines, resize handles, group labels and proximity feedback |
| `CanvasSpatialIndex.swift` | Shared world-space queries for visibility, hit testing and nearby placements |
| `CanvasAssetStore.swift` | Bundled image lookup, resolution tiers, alpha masks, preparation and memory budget |
| `CanvasHistory.swift` | Reversible completed operations; one interaction equals one history entry |
| `CanvasPersistence.swift` | Versioned JSON snapshots and serialized atomic writes |
| `CanvasExporter.swift` | Offscreen group composition from saved geometry and original sample assets |
| `CanvasFixtures.swift` | Hardcoded product metadata, initial layout and deterministic stress layouts |
| `CanvasConfiguration.swift` | Named, tunable limits and interaction constants |

`ContentView` should become a thin entry point to `CanvasScreen`, not the canvas engine itself.

Use one stable `CanvasSession` instance per canvas. SwiftUI observes selection summaries, history availability, loading/errors, and completed edits. Camera and finger-movement updates must not publish the entire document through SwiftUI each frame. `updateUIView` must be idempotent and must not reset geometry, recreate recognizers, or reapply the initial camera.

Route UI actions through explicit session commands, not booleans that can replay whenever SwiftUI updates. Disable document-changing toolbar actions during an active manipulation; allow them again after completion or cancellation. Presentation of modal UI must first resolve the active interaction. Avoid retain cycles in callbacks, observers and display links.

## 4. State model and invariants

Use stable IDs, preferably deterministic IDs for seed records and UUIDs for new placements.

- `SampleProduct`: ID, title, optional brand/category/notes, local image asset ID, and intrinsic trimmed aspect ratio.
- `StickerPlacement`: ID, product ID, world centre, positive world width/height, optional group ID.
- `CanvasGroup`: ID, optional name. Keep membership canonical in placement `groupID` values; derive member lists rather than maintaining two conflicting sources of truth.
- `CanvasDocument`: schema version, products or product references, placements, groups, and an ordered list of placement IDs from back to front.
- `CanvasCamera`: world centre and positive zoom. Store separately from document editing history.
- `CanvasSelection`: none, placement ID, or group ID; transient and not essential to persistence.

Use `Double` for saved world geometry, converting camera-relative values to `CGFloat` at the rendering boundary. Explicit point/size structs can make Codable storage and pure geometry tests simpler. Reject nonfinite coordinates and invalid sizes on load and mutation.

Every placement occurs exactly once in stacking order. A duplicate references the same product but has independent geometry and group membership. Deleting a placement leaves its product available. Clean up empty groups and dissolve singleton groups after deletion or detachment.

Layers are projections of model state. Maintain transient edit geometry during manipulation and commit the final patch once; rendering, hit testing and proximity must all consult the same effective geometry. Do not let them read stale saved positions while an image is being dragged.

## 5. Hardcoded image fixtures

Provide at least six visually distinct local sample images: top, jacket, trousers, shoes, bag and an accessory. Include opaque and transparent content, different aspect ratios, and one image with an interior transparent gap for hit-testing validation.

Bundle actual raster files and a small metadata catalog. No runtime remote URLs or photo permissions. If clothing art is unavailable, create simple garment-shaped fixture illustrations using a one-time drawing/export utility and bundle the generated PNGs. Clearly treat them as sample artwork; asset sourcing must not block the canvas.

Prefer bundle resource files for image sources so Image I/O can downsample before full decoding. Verify target resource inclusion. Trim transparent outside margins once during fixture preparation and keep alpha masks aligned with the trimmed image. Preserve originals if the fixture pipeline performs trimming.

Seed approximately 12 placements on first launch only, including deliberate overlap and items outside the initial viewport. An empty saved board stays empty on relaunch. Add a toolbar `+` that opens the sample catalog; choosing a product creates another placement near the viewport centre with a small deterministic offset. Insert at the front, select it, and record one undoable add operation.

## 6. Camera and rendering

Use the following no-rotation equations consistently:

```text
screen = viewportCentre + (world - cameraCentre) * zoom
world  = cameraCentre + (screen - viewportCentre) / zoom
```

Start at zoom `1`. Initial zoom limits: `0.1 ... 8`. Centralize these values. The world has no fixed content rectangle; zoom limits do not constrain panning distance.

For camera pinch, save starting centre, zoom and midpoint. Compute the world anchor at the starting midpoint. For every update, clamp the new zoom first, then set:

```text
newCameraCentre = anchorWorld - (currentMidpoint - viewportCentre) / newZoom
```

This handles simultaneous midpoint translation and zoom without independently applying pan translation a second time. Keep camera centre stable across viewport size changes. Cancel an active edit cleanly before a size transition if its baseline cannot remain valid.

Create a clipped canvas view containing a world layer and a screen-space overlay. Represent the camera using a transform on the internal world layer with explicitly configured anchor/position semantics. Keep child positions relative to a nearby render origin. Rebase when the camera becomes distant from that origin, atomically updating layer positions and camera transform without changing persisted coordinates. Do not create an enormous backing bitmap or world-sized view.

Use one `CALayer` per materialized placement, with shared prepared `CGImage` contents. Disable implicit animations around direct manipulation and visibility reconciliation. Preserve aspect ratios. Do not blindly enable layer rasterization, per-image shadows, or unnecessary masks.

Reconcile only layers entering/leaving the visible region or changing geometry, contents, selection, or stacking. Camera changes update the world transform and visibility query; they should not rewrite every document position. Always retain actively manipulated items until their interaction ends. Return offscreen layers to a bounded pool and clear image references when recycling them.

Optional background dots must be viewport-sized, sparse at low zoom, and derived from camera position; never create a layer per world-grid point.

## 7. Interaction contract

Implement explicit states: idle, camera pan, camera pinch, placement drag, placement pinch, corner resize, group drag, group pinch, and member detach. Each state owns its target, initial geometry, current effective geometry and transaction ID.

Attach a small set of recognizers to the root canvas, not each image: tap, one-finger pan, two-finger pan, pinch and long press. Use delegate filtering and narrowly defined simultaneous recognition. The interaction controller decides ownership; recognizer callback ordering must not determine product behaviour.

| Input | Required result |
| --- | --- |
| Tap visible image pixels | Select the frontmost hit and show its name, category and Info action in a compact nonmodal card |
| Info action | Open the full hardcoded metadata sheet |
| Tap empty space | Clear selection and compact card |
| One-finger drag on image | Move that image; a grouped member moves its group unless detachment was activated |
| One-finger drag on empty space | Pan camera |
| Two-finger drag without qualifying image resize | Pan camera, including over a crowded board |
| Pinch beginning within the already selected ungrouped image's bounds | Resize the image uniformly |
| Pinch beginning within selected group's union bounds | Scale group uniformly |
| Other pinch | Zoom and translate camera |
| Drag selected corner handle | Resize image or group about the opposite corner |
| Drag group label | Select and move the group |
| Long press a grouped member, then drag | Detach and move that member as one undoable operation |

For an image pinch, both initial touches must be inside the selected image's bounds and at least one must alpha-hit that selected image without an unrelated higher image intercepting it. For a group pinch, both touches must be inside its selection bounds and at least one must hit a group member. Otherwise use camera navigation. Remember initial touch eligibility before recognition crosses its movement threshold.

For grouped member taps, expose that member's information while selecting its group for transforms. Keep an explicit inspected-member ID to avoid ambiguity. Group labels provide a naming action distinct from dragging.

Camera two-finger pan and camera pinch may recognize simultaneously, but feed one camera transaction. Once pinch is active, its midpoint translation owns the camera motion. Placement/group resizing suppresses camera movement.

When a second finger arrives during a one-finger drag, perform a deliberate transition: retain current effective geometry, evaluate pinch eligibility, and capture a fresh baseline. Preserve the original edit snapshot so cancellation restores the whole interaction. If transitioning to camera navigation, finish the pending object edit once before starting the camera transaction; document this boundary and test it. Once a pinch target is chosen, keep it until the pinch ends. After one finger lifts, require all fingers to lift before beginning a new one-finger operation; this prevents accidental post-pinch drags.

For image pinch scaling, save the local normalized anchor beneath the initial midpoint. With new uniformly scaled size, compute the centre so that anchor stays under the current midpoint in world coordinates. Do not merely scale about the image centre. Initial size range: longest edge `24 ... 8192` world units; preserve aspect ratio when clamping. Group limits must respect every member's size constraints.

Keep handles about 44 screen points in hit area regardless of camera zoom. Hit-test handles and labels before images. Prevent tap from firing after drag, pinch or long press, without introducing unnecessary long-press delays into ordinary dragging.

On cancellation, restore starting geometry, stacking and memberships and clear previews. On completion, create one history operation for the whole edit. A no-op gesture must not create history. Cancel on app backgrounding, view teardown, or loss of a valid target.

Add camera momentum after direct manipulation is correct. Use elapsed time and screen-space velocity, with a `CADisplayLink` only while decelerating. Stop immediately on new touch, backgrounding, or teardown. Do not run a permanent idle render loop.

## 8. Layering, spatial queries and hit testing

On the first real movement in an image drag, raise it to the front. Include this reorder in the drag transaction and roll it back if canceled. Tapping alone does not reorder. Raising a group moves its members to the front as a stable block, preserving their previous relative stacking. Culling and recreating layers must preserve global stacking.

Start with a uniform world-space hash grid using 512-unit cells behind a replaceable query interface: `insert`, `remove`, `update`, and `query(rect)`. Store each placement in all intersected cells and deduplicate query results. Use floor division for negative coordinates.

Avoid enormous cell loops: placements covering more than 64 cells go into an oversized-item collection, checked by bounds on queries. For queries spanning more than 4096 cells, scan indexed placement bounds instead of iterating every empty cell. Keep these caps configurable. Index current effective geometry incrementally; camera pan/zoom never rebuilds it.

Visibility uses the viewport converted to world coordinates plus roughly 200 screen points of overscan. A hit test queries a small world-space region around the touch, sorts candidates front to back, maps the touch into image coordinates, and samples a cached alpha mask. Transparent areas pass through to lower placements. Missing masks may temporarily use bounds, but must not synchronously decode on touch handling.

Use a low-resolution mask, approximately 128–256 pixels on its longest edge, prepared once per asset. Normalize image orientation. Start with an alpha threshold around 0.1 and a small screen-space tolerance; ensure tolerance does not turn large transparent gaps into solid hits. Derive visual bounds and mask mapping from the same trimmed source.

## 9. Proximity and magnetic grouping

For each moving/resizing placement, query its bounds expanded by the grouping radius. Exclude itself and members moving as part of the same group. Compute rectangle edge distance:

```text
dx = max(other.minX - moving.maxX, moving.minX - other.maxX, 0)
dy = max(other.minY - moving.maxY, moving.minY - other.maxY, 0)
distance = sqrt(dx * dx + dy * dy)
```

Overlapping bounds have distance zero; also calculate positive-area intersection separately so touching and overlap can be distinguished. Bounds-based proximity is the initial product rule; alpha-aware picking does not imply pixel-perfect garment collision.

Use `24 / zoom` world units as the initial join radius, and `36 / zoom` as the preview-release radius. Hold the current candidate until it exceeds the larger radius; rank new candidates by distance, then frontmost order, then stable ID. This prevents flickering between equally close neighbours.

Show a subtle outline connecting the moving selection and candidate group/item. Do not snap or move existing items merely because they are close. Commit membership on successful release only. Never regroup the board continuously while idle or navigating.

Joining two ungrouped items creates a group. Joining an existing group adds members. Joining two groups merges them into the target group and preserves its name, using the source name only if the target is unnamed. Geometry stays unchanged; membership does not create a nested layer hierarchy. Undo restores both original groups and names.

Group transforms use original member centres/sizes and a shared anchor. During group proximity queries, compare actual member bounds to candidates, not only the union rectangle, which may contain large empty gaps.

Long-press detachment is explicit: temporarily exclude the member from its old group, suppress rejoining that group for the rest of the gesture, and commit membership and movement together on release. Cancel restores both. This is distinct from preview hysteresis; do not require tearing the member through an invisible distance threshold.

## 10. Asset preparation and performance controls

Use resolution tiers such as 256, 512, 1024 and 2048 pixels on the longest edge, capped at source dimensions. Choose based on displayed size in points multiplied by display scale. Keep an existing tier during small zoom fluctuations; upgrade when materially undersized and downgrade only after zoom settles.

Downsample through Image I/O from source files. Cache by asset ID and tier, share images across repeated placements, coalesce duplicate requests, and validate placement/asset/request identity before applying async results. Cancel or deprioritize requests no longer needed; cancel a shared request only when no consumers need it.

Set an initial prepared-image cache budget of 96 MiB by decoded byte cost, with bounded concurrent preparation, initially two jobs. Treat this as a tunable cache limit, not a guarantee on total process memory: visible layers retain images too. Track pinned visible-image costs, lower resolution under pressure, clear offscreen cache entries on memory warnings, and avoid immediately reloading discarded tiers. Use `bytesPerRow * height` where available for image costs.

Because default isolation is `MainActor`, explicitly isolate decoding and file I/O on a background worker. Verify expensive synchronous work actually runs off the main actor; merely wrapping it in `Task {}` is insufficient. Keep UIKit creation/manipulation and visible layer changes on the main actor. Resolve concurrency diagnostics without blanket unchecked sendability.

At minimum zoom many images may all be visible. Never claim culling solves that case. Implement low-resolution overview tiers first, measure density, and document any practical limit. Do not silently hide placements to meet a frame-rate target. Further overview aggregation or another renderer requires an explicit measured rationale.

## 11. History, persistence, export and accessibility

Implement compact before/after patches for affected placements, groups and order changes. Do not store image bytes or a document copy on every gesture event. Bound history to a reasonable starting limit, such as 100 completed edits. New edits clear redo. Include add, duplicate, delete, move, resize, group, detach and rename. Camera navigation is outside document undo.

Persist a versioned JSON document and camera snapshot in Application Support. Load once; use seeds only when no save exists. Serialize writes and ensure an older snapshot can never overwrite a newer one. Save after committed edits, debounce camera saves, and flush pending completed state when backgrounding. Use atomic replacement. Report failures visibly without destroying current work. Preserve unreadable saves for diagnosis and offer an explicit reset rather than silently overwriting them. Rebuild spatial indexes and renderer state on load; do not persist caches, selection or layers.

Export a selected group from model geometry and source assets into a transparent PNG, longest edge initially 2048 pixels with a strict output pixel cap. Preserve stacking, aspect ratios and inter-item placement; exclude handles, cards and labels. Share through the system share sheet. Use background preparation where safe and report errors. Export must agree visually with the canvas at any camera zoom and include members currently offscreen.

Expose visible/selected items and group controls as accessibility elements with product labels and updated screen geometry. Provide accessible Info, Select, Delete, Duplicate, Move and Resize actions or buttons, plus camera Zoom In/Out and Fit All. Provide member selection without requiring precise alpha hits. Keep focus stable through culling where practical and do not expose every offscreen placement as an enormous accessibility tree.

## 12. Sequential implementation checkpoints

Complete each checkpoint before moving to the next. Build frequently; do not defer integration until all components exist.

1. **Shell and fixtures:** replace starter UI, bundle sample assets, seed document, host a stable UIKit view, show images and compact metadata UI. Verify offline launch and sample addition.
2. **Geometry and camera:** implement pure geometry, anchored camera pinch, panning, zoom clamps, render origin and Fit All. Verify distant coordinates and viewport resizing.
3. **Editing and arbitration:** implement selection, alpha picking, drag, image pinch, corner resizing, two-finger navigation, stacking and cancellations. Exercise second-finger transitions before adding groups.
4. **Spatial and image pipeline:** integrate the index, visibility reconciliation, tiers, worker decoding, bounded cache and stale-result protection. Verify repeated assets share prepared images and offscreen layers are released.
5. **Groups:** implement proximity feedback, hysteresis, release-to-join, labels/naming, group transforms and detachment. Verify overlap remains freeform and group operations preserve stacking.
6. **Durability:** finish operation history and serialized persistence. Verify every edit category with undo/redo and relaunch, including an intentionally empty board.
7. **Completion:** add export, accessibility controls, momentum, debug workloads and diagnostics. Run acceptance scenarios, profile where hardware is available, and record remaining limits accurately.

History transaction hooks and effective geometry should exist from checkpoint 3 even though full history/persistence validation occurs in checkpoint 6.

## 13. Tests and acceptance scenarios

Add a unit-test target for consequential pure geometry and state-machine behaviour. Keep tests focused on invariants and regressions, not private implementation details.

Required automated checks:

- World/screen round trips at negative and large coordinates and min/max zoom.
- Camera and image pinch anchors remain beneath a translating midpoint, including at clamps.
- Group scaling preserves relative geometry and aspect ratios.
- Index queries match brute-force rectangle intersection for deterministic random layouts, negative cells, oversized objects and incremental moves.
- Alpha hits pass through transparent regions and obey global stacking.
- Proximity distinguishes overlap/touch/separation and remains consistent in screen points across zoom levels.
- Candidate hysteresis and stable tie-breaking prevent switching noise.
- Drag-to-pinch transitions neither double-apply movement nor create duplicate history entries.
- Cancellation restores geometry, stacking, group membership and index state.
- Undo/redo restores joins, merges, detachment, duplicate/delete and redo invalidation.
- Persistence round trips preserve IDs, order and geometry; malformed input does not overwrite a good document.

Manual acceptance checklist:

- Launch offline, add every sample type, overlap images, tap through a transparent gap, and inspect the correct metadata.
- Pinch empty space and unselected content to navigate; select an image and pinch it to resize without changing the camera.
- Pan a densely covered board with two fingers. Add/remove fingers during gestures and confirm no jumps or unintended drags.
- Resize at limits; handles stay usable when zoomed out. Move far from the origin and return with Fit All.
- Join, merge, rename, move, scale and detach groups; cancel edits and undo/redo them.
- Rotate the device, background the app during a drag, reopen details, and relaunch after edits.
- Delete all placements and relaunch without reseeding. Add new placements afterward.
- Export a partly offscreen group and compare its layering and proportions with the canvas.
- Exercise VoiceOver or accessibility inspector plus the alternative editing controls.
- Pan repeatedly across an uncached board, zoom in/out, and confirm stale async images never appear on recycled layers.

Discover installed Xcode schemes and simulator destinations before choosing build commands:

```sh
xcodebuild -list -project ios/Garms.xcodeproj
xcodebuild -showdestinations -project ios/Garms.xcodeproj -scheme Garms
```

Then build/test against an available iOS simulator using a derived-data directory outside tracked source. Verify the created test target is included in the scheme. If the required SDK/runtime is missing, record that blocker precisely; do not claim the build or gestures passed.

## 14. Performance validation and final handoff

Provide a Debug-only fixture selector for 100, 500 and 2,000 placements. Use deterministic sparse and dense layouts, repeated assets, mixed source sizes, and a separate unique-image stress fixture generated locally. Six repeated source images cannot validate unique-image memory behaviour; label workloads honestly.

Expose lightweight counters for materialized layers, placement count, prepared-image bytes, in-flight requests and spatial-query candidate counts. Avoid per-frame console logging. Use Instruments for main-thread work, animation hitches, allocations and rendering pressure on physical hardware when available.

Exercise continuous pan/pinch, dense transparent overlap, zooming out to show all items, rapid direction changes and background sample-image preparation. Aim for responsive 60 Hz interaction and 120 Hz on supported hardware. Report measured device, OS, workload and build configuration; simulator observations do not establish device performance. Confirm there is no active display link or repeated document rendering at idle and that memory settles after repeated navigation.

The implementation agent's final handoff must include:

- What was implemented and any deliberate deviation from this interaction contract.
- Build/test results and which manual scenarios were actually exercised.
- Where fixture counts, zoom limits, proximity thresholds and cache budgets can be tuned.
- Actual performance observations, separately from unmeasured targets.
- Remaining defects or environment blockers, with no unsupported “infinite capacity” claims.

Leave the app runnable from `ContentView`, retain existing user changes, and do not commit or publish unless separately asked.

# Automatic background removal for shared products

Status: implemented with deterministic checks and unsigned app/extension build passing on 26 September 2026. A signed iPhone 17 Pro / iOS 26.6.2 Vision smoke run passed four cases; full share-sheet/UI acceptance and difficult-background quality remain pending. See README for validation results. Decisions confirmed 26 September 2026.

This is a self-contained handoff for one implementation agent. Read the files below, implement the steps sequentially, validate, and update the documentation. Do not delegate or create separate tasks. Paths in this document are relative to the repository root. The code inspection reflects 26 September 2026; verify symbols against the checkout before editing and preserve unrelated working-tree changes.

## Read first: existing code and documentation

| File | Current implementation and relevance |
| --- | --- |
| [PRODUCT_SPEC.md](PRODUCT_SPEC.md), collecting clothing | Agreed cutouts, preserved originals, whole-person acceptance and combined subjects. |
| [SHARED_LINK_IMPORT_WALKTHROUGH.md](SHARED_LINK_IMPORT_WALKTHROUGH.md) | Explains the implemented extension, inbox, API, coordinator and asset ownership. |
| [SHARED_LINK_IMPORT_PLAN.md](SHARED_LINK_IMPORT_PLAN.md) | Historical import constraints and acceptance cases. Its background-removal exclusion is superseded by this plan. |
| [CANVAS_IMPLEMENTATION_NOTES.md](CANVAS_IMPLEMENTATION_NOTES.md) and [CANVAS_IMPLEMENTATION_PLAN.md](CANVAS_IMPLEMENTATION_PLAN.md) | Canvas interactions, image tiers, masks and main-actor constraints. Historical plans are context, not additional implementation scope. |
| [README.md](../README.md) | Xcode build, signing, device API setup, check commands and existing limitations. |
| [ImportCoordinator.swift](../ios/Garms/Imports/ImportCoordinator.swift) | `Item`, `setActive`, `start`, `process`, `valid`, `retry`, `dismiss`, `deleted`. Sequential processing with injectable API and image closures. Currently downloads then immediately marks Ready. |
| [ImportedAssetLibrary.swift](../ios/Garms/Imports/ImportedAssetLibrary.swift) | Main-actor `sources` map and `insert`/`retain`; `ImportedImageDownload.fetch` enforces 10 MB downloads, rejects invalid dimensions, normalises/downsamples to 2,048 pixels and returns PNG `Artwork(data:aspect:)`. |
| [CanvasDocument.swift](../ios/Garms/Canvas/CanvasDocument.swift) | `SampleProduct` is Codable/Equatable/Sendable; `asset` and `aspect` describe the displayed artwork. Fixtures rely on its existing initializer defaults. |
| [CanvasSession.swift](../ios/Garms/Canvas/CanvasSession.swift) | Owns `importedAssets` and lazy `imports`. `insertImport` waits for initial layout. `updateImport` preserves current centre/longest edge. `deletePlacement`, failed insertion and artwork updates each retain only `product.asset` today. |
| [CanvasAssetStore.swift](../ios/Garms/Canvas/CanvasAssetStore.swift) | `CanvasImageWorker.resolve`/`decode`/`mask`, tier cache keyed by asset and resolution, 192-pixel alpha mask, `hit` with alpha threshold 25/255, disposable caches on `memoryWarning`. |
| [CanvasScreen.swift](../ios/Garms/Canvas/CanvasScreen.swift) | Scene phase activates/pauses imports. Imports sheet and toolbar compare state strings. `productDetails(for:)` reads `session.revision`; `CanvasGroupItemThumbnail` reloads with `.task(id: asset)`. |
| [CanvasImageDetails.swift](../ios/Garms/Canvas/CanvasImageDetails.swift) | One imported image, currently loaded into `productImage` with `.task(id: product.asset)`. Must accommodate independently keyed original/cutout images. |
| [CanvasRenderer.swift](../ios/Garms/Canvas/CanvasRenderer.swift) and [GarmsCanvasView.swift](../ios/Garms/Canvas/GarmsCanvasView.swift) | Existing renderer/library wiring. Transparent artwork should use this path without renderer redesign. |
| [ImportSessionChecks.swift](../ios/tools/checks/ImportSessionChecks.swift) | Existing injected async import checks, geometry preservation, duplicates, backgrounding, deletion and derived-cache recovery. Extend this pattern. |
| [run-canvas-check.sh](../ios/tools/checks/run-canvas-check.sh) | Compiles imports via `ios/Garms/Imports/*.swift` plus selected canvas files for Apple Silicon Mac Catalyst, then runs one check entry point. |
| [project.pbxproj](../ios/Garms.xcodeproj/project.pbxproj) | iOS 26.2 deployment, MainActor default isolation, synchronized app source folder. Verify the new app file is included without adding it to the share extension. |

No backend or extension changes are expected. If backend work becomes necessary, read [web/AGENTS.md](../web/AGENTS.md) first and explain why scope changed.

## Agreed behaviour

- Automatically remove the background from the image downloaded through the existing shared-link import flow.
- A whole person wearing the clothes is an acceptable subject. Garment-only extraction is outside this feature.
- Keep all detected foreground subjects together as one sticker, including separated objects such as a pair of shoes. Do not select only the largest subject or split subjects into products.

## Proposed experience

Continue showing the saved-link placeholder while fetching the image. Show the downloaded image as soon as it is ready, then replace it with a transparent cutout when processing completes. Keep the current placement centre, longest edge and stacking order when the cropped image changes aspect ratio. Resolve any active interaction before applying the change, then use the latest placement geometry.

Use the cutout on the canvas and in group thumbnails. Provide labelled Original and Cutout views in product details when both exist; show only the original if extraction fails. Preserve the source link and metadata throughout.

If Vision fails or finds no foreground subject, keep the original and consider the import successful. Distinguish this outcome from an image download failure, which continues to use the existing import failure/retry flow. A brief non-blocking status such as “Background kept” can explain the fallback without interrupting the user. Manual subject selection and mask editing are deferred. Following the simulator inference failure report, a background-removal retry control now reuses the saved original. Vision internal errors also receive one automatic retry with a supported GPU, and logs identify simulator runs; this does not guarantee simulator inference support.

## Processing

Use Apple's Vision `VNGenerateForegroundInstanceMaskRequest`. Pass the observation's `allInstances` to `generateMaskedImage(ofInstances:from:croppedToInstancesExtent:)`, with cropping enabled. Preserve relative positions between all foreground instances and encode the result as a PNG with alpha. Do not substitute person segmentation: clothing without a person must also work.

Run processing in the containing app, after the existing bounded download and orientation-normalising decode. Retain the current 2,048-pixel longest-edge bound. The preserved original means this bounded, normalised source image, consistent with the current importer; this feature does not retain an additional full-resolution download.

Run Vision and image encoding explicitly off the main actor, one image at a time. Merely wrapping synchronous processing in a main-actor Task is insufficient. Check cancellation around expensive work and before publishing results. Validate nonempty foreground instances and a finite, positive output size; unusable output falls back to the original.

The app currently targets iOS 26.2. Verify SDK API availability and physical-device execution during implementation. No new backend service or share-extension processing is required.

## Code changes

1. Add `ios/Garms/Imports/ForegroundCutoutProcessor.swift`: a background worker taking bounded image data and returning cutout data/aspect or a no-cutout outcome. Keep cancellation distinct from extraction failure; inject the worker into the coordinator for deterministic checks.
2. Extend `SampleProduct` in `CanvasDocument.swift` with an optional original asset reference. Keep `asset` as the current canvas artwork key so renderer and thumbnail lookup remain compatible with fixtures.
3. Update `ImportedAssetLibrary` and every session cleanup path to retain all referenced original and displayed artwork keys. Reuse the same key when the original is also the displayed artwork. Give successful cutouts new keys so prepared image tiers and touch masks cannot remain stale.
4. Extend `ImportCoordinator` to publish the original before extraction, retain that completed stage, and then publish the cutout. Track extraction progress separately from network failure. Backgrounding requeues unfinished extraction; reactivation should reuse the downloaded original rather than repeat scraping/downloading. Keep one processor and the existing attempt/placement guards; late results after deletion, dismissal or retry must be ignored.
5. Extend `CanvasSession` updates to preserve originals and replace only the displayed artwork. Keep current geometry preservation, validation and observed revision updates. Geometry changes should use normal group reconciliation rather than force obsolete group membership.
6. Update `CanvasImageDetails` to expose the original and cutout, including when the sheet is already open as processing finishes. Canvas and group thumbnails continue using the displayed asset.

## Implementation sequence and contracts

### 1. Add original-image ownership and session mutations

Add `originalAsset: String? = nil` to `SampleProduct`. Missing original references must decode as nil, preserving existing fixture JSON and initializer call sites. Add a computed set of referenced asset keys, containing `asset` and `originalAsset` when present; do not store duplicate bytes to represent the same original twice.

Centralise session asset cleanup in a helper using the union of these references across `document.products.values`. Replace all three current `importedAssets.retain(Set(document.products.values.map(\.asset)))` paths: successful deletion, insertion rollback and artwork update. Search again for retain calls after editing. Prune against the final validated document, including after rollback.

Make original installation and cutout replacement explicit operations, for example `installImportOriginal(_:title:artwork:)` and `applyImportCutout(_:artwork:)`. Retain the existing title-only update or an equivalent. Installing an original assigns the same new key to `asset` and `originalAsset`. Applying a cutout changes `asset`/`aspect` but preserves `originalAsset`. Return success or the installed asset key so the coordinator cannot mark a rolled-back mutation complete. Update existing checks/call sites if `updateImport` is replaced.

Reuse the current update pattern: guard placement/product, resolve interaction, re-read current placement, snapshot document, mutate, validate/refresh, then prune unused assets. Never reset camera, selection, product URL or stacking order on cutout completion. Keep geometric group reconciliation performed by `refresh`; cropping may legitimately change proximity membership. Preserve the current longest edge, not the original imported size if the user has resized it.

### 2. Implement a bounded foreground worker

Use a `nonisolated` worker with a Sendable data boundary. A suitable contract is `extract(_ source: ImportedImageDownload.Artwork) async throws -> ImportedImageDownload.Artwork?`: artwork means success, nil means no usable cutout, cancellation throws. The coordinator catches non-cancellation processing errors and uses the original. Do not pass UIKit views, session state or Vision observations between actors.

Inside an explicitly off-main synchronous work unit:

1. Decode the normalised bounded PNG to a CGImage; use orientation `.up` because the downloader already applies orientation. Do not decode the unbounded network payload again.
2. Create `VNImageRequestHandler(cgImage:orientation:options:)` and `VNGenerateForegroundInstanceMaskRequest`; perform the request.
3. Require a result with nonempty `allInstances`. Use all foreground instances, never instance 1 or a largest-component heuristic.
4. Generate the masked image using that same handler and `croppedToInstancesExtent: true`.
5. Convert the pixel buffer through Core Image to CGImage and encode a PNG with ImageIO. Preserve alpha, soft edges and gaps between subjects. Do not flatten against white or add borders/shadows.
6. Check positive dimensions, the output pixel bound, and at least some nonzero alpha. A completely transparent result is unusable; a solid result is not automatically a failure (a subject may fill the frame). Return the cropped aspect ratio.

Keep Vision, Core Image objects and intermediate buffers local to the worker. Release temporaries after each image. Preserve existing source transparency during composition and verify already-transparent inputs on device.

Cancellation must not create overlapping Vision requests: cancellation of a parent does not automatically cancel a detached task. Hold and cancel the worker task where appropriate, check cancellation between synchronous stages, and await its completion before allowing the next processor to start. If synchronous Vision work cannot stop immediately, let it finish and discard the stale result. Do not add unchecked Sendable annotations merely to silence actor diagnostics.

### 3. Add resumable extraction to the existing coordinator

Preserve top-level Queued/Processing/Ready/Failed behaviour for minimal UI disruption. Add a small processing-stage enum (`fetching`, `downloading`, `removingBackground`), a nonfatal note, and a checkpoint containing the installed original asset key and aspect. The checkpoint references session-owned data rather than retaining a second long-lived copy of the image. Existing API and image injection remain; add an injected cutout closure with the production worker as its default.

| Transition | Required action |
| --- | --- |
| Queued without original checkpoint | Keep the current fetch/title/download sequence and guards. |
| Download succeeds | Check attempt/placement, install original, save its key/aspect only after installation succeeds, and publish removing-background progress. |
| Queued with valid checkpoint | Resolve original data from `importedAssets`, skip API/download, and resume extraction. |
| Extraction succeeds | Check attempt/placement again, apply cutout, then mark Ready. |
| Extraction returns nil or a processing error | Keep original, mark Ready and set the nonfatal note “Background kept”. Do not populate `failure`. Offer “Retry background removal” using the saved original checkpoint. |
| API/image download fails | Preserve existing Failed state, message and explicit Retry. |
| App becomes inactive | Cancel processor, invalidate active attempts, requeue Processing items, retain any installed original checkpoint. Do not treat cancellation as fallback success. |
| App becomes active again | Existing `processor == nil` guard prevents overlap. Resume queued work after any old worker has actually finished. |
| Item deleted/dismissed | Ignore late results; never reinstall assets or recreate placement. Release checkpoint when removing Item. |

Keep placeholder insertion for all queued links before serial processing starts, deduplication, inbox acknowledgment and initial-layout gating unchanged. Check validity after every await and before library/document mutation. Do not hold an array index across await because deletion changes indices. Missing checkpoint data should invalidate the checkpoint and restart normal import once, not loop indefinitely.

The current `setActive(false)` resets only items with state `Processing`; if using typed states or additional top-level states instead, update every consumer together. The current `valid` checks active state, attempt and placement existence; retain all three conditions. Cancellation-insensitive providers must still be safe.

### 4. Expose progress and both images

In `CanvasScreen`, show “Removing background…” while that stage runs. Completed fallback items should have the Ready state, disappear from the outstanding count, and display “Background kept” in the existing Imports sheet. Keep Dismiss semantics unchanged: it removes the placement. No modal error for extraction failure.

In `CanvasImageDetails`, build imported image pages from keys: display the cutout first, labelled “Cutout”, then “Original” when the keys differ. Before extraction or on fallback, show one original page. Preserve the existing fixture presentation. Each page should own an async decode keyed by its asset, using the shared resolver at tier 1024 with a cancellation guard. Do not use a single `productImage` state for two different pages. Update accessibility labels and page counts.

Keep `productDetails(for:)` observing revision so an already-open details sheet sees the new original/cutout keys. Group thumbnails already reload on the displayed asset key and should need no new source selection. Unique cutout keys also produce new renderer tiers and masks; do not rewrite the renderer or mutate bytes beneath an existing key.

### 5. Add checks, build and document results

Extend `ImportSessionChecks.swift` or add `ForegroundCutoutChecks.swift` using the existing runner. Inject a deterministic cutout result into every successful-import test that would otherwise invoke the new production default, including the existing `ready` coordinator. Existing synthetic placeholder artwork is not an appropriate real-Vision fixture.

Use continuations or controlled test gates to pause extraction and verify the original has appeared before release. Test the following boundaries:

- Success: original and cutout have different keys, both data blobs remain available, one placement remains, the current centre/longest edge/order survive replacement, and document validation passes.
- Nil and thrown extraction errors: original remains visible, import is Ready with a nonfatal note, and no network retry occurs.
- Inactivity during extraction: original remains, no stale result is published, reactivation calls extraction again without API/download repetition, and peak worker concurrency stays at one even if the first worker ignores cancellation.
- Delete/dismiss during extraction: no recreated product/placement or newly retained result. Ensure the test exercises the same coordinator that receives deletion, or explicitly notify an injected coordinator; standalone coordinators in existing checks are not `session.imports`.
- Asset lifetime: both keys survive `CanvasAssetStore.memoryWarning`; deleting the last referencing product releases both, while a reference held by another product is retained.
- Alpha handling: generate a synthetic transparent image with two opaque separated regions, verify PNG decode preserves alpha and `CanvasImageWorker.mask`/`CanvasAssetStore.hit` reject the gap and accept both regions. This checks our storage/rendering boundary, not Vision's subject detection quality.
- Compatibility: fixture JSON without `originalAsset` still decodes, sample artwork still resolves, repeated shares still reveal the existing item, and insertion still waits for initial layout.

Run from the repository root, sequentially (the check runner reuses one output binary):

```sh
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/ImportSessionChecks.swift
# If added:
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/ForegroundCutoutChecks.swift
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/InitialLayoutChecks.swift
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/SearchChecks.swift
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/AvailabilityChecks.swift
xcodebuild -project ios/Garms.xcodeproj -scheme Garms -destination 'generic/platform=iOS' -derivedDataPath /tmp/garms-ios-build CODE_SIGNING_ALLOWED=NO build
```

The runner's wildcard already includes the new worker. If Vision/Core Image linkage or Catalyst compilation needs adjustment, limit runner edits to that requirement and keep actual Vision inference out of deterministic checks. No backend tests are required for documentation and iOS-only changes. The README records a pre-existing magnetic-drag cancellation assertion failure; if interaction/grouping code is touched, run that check and distinguish baseline failures from regressions rather than expanding this feature to fix unrelated behaviour.

After automated verification, perform the physical-device scenarios below if a signed device is available. Otherwise finish code/build/checks and explicitly list device validation as pending. Update README and the walkthrough with source/cutout ownership, fallback, processing location and the unchanged session-only lifetime. Report changed files, exact checks and results, device/OS observations, and remaining limitations. An unsigned build proves compilation, not segmentation quality or a working share sheet.

## Validation

Automated checks should inject successful, empty, failing and delayed cutout results. Verify one placement survives original-to-cutout replacement, the latest centre/size/order are preserved, both assets survive derived-cache eviction, and deletion releases unused assets without deleting shared references. Check background/reactivation, repeated activation and stale completions after deletion or dismissal. Confirm a cutout failure yields a usable original and a completed import rather than a failed import.

Build the iOS app and extension and run the relevant existing import/session checks. Use synthetic alpha-bearing artwork for deterministic rendering/mask checks; avoid asserting exact Vision output pixels.

On a signed physical iPhone, share product images covering flat clothing, a person wearing clothes, a pair of shoes, multiple separated subjects, already-transparent artwork and a difficult background. Confirm transparent areas allow touches through to lower stickers, details can show the original, thumbnails match the canvas, pan/zoom stay responsive, and returning from inactivity resumes safely. Record actual processing time and observed cutout quality; do not promise perfect segmentation or infer device behaviour from a simulator build.

## Scope and documentation

This extends the completed shared-link importer and supersedes its historical exclusion of background removal only for this feature. It does not add persistence: originals and cutouts remain in session memory and disappear on termination, like existing consumed imports. Existing bundled samples remain unchanged.

Update the README and import walkthrough after implementation so they describe verified behaviour. The broader requirement to preserve originals and generate stickers is in [PRODUCT_SPEC.md](PRODUCT_SPEC.md#images-and-automatic-cutouts--agreed).

## Apple references

- [Foreground instance mask request](https://developer.apple.com/documentation/vision/vngenerateforegroundinstancemaskrequest)
- [Generate a masked image for selected instances](https://developer.apple.com/documentation/vision/vninstancemaskobservation/generatemaskedimage%28ofinstances%3Afrom%3Acroppedtoinstancesextent%3A%29)
- [Lift subjects from images in your app](https://developer.apple.com/videos/play/wwdc2023/10176/)

Apple's session explains the class-agnostic foreground extraction, `allInstances`, cropping and off-main execution used by this design. Use installed SDK declarations as the final authority for signatures and platform availability; external references were checked on 26 September 2026.

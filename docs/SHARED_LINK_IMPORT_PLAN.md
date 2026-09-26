# Shared-link import: bare-bones implementation plan

Status: ready for implementation; no feature code implemented by this plan.
Date: 26 September 2026.

## Objective and agreed scope

Build the smallest end-to-end demonstration: share a product page from another app, choose Garms, capture its URL, open Garms, fetch a title and image, and place the result on the existing canvas. The canvas, imported products, downloaded artwork and processing status remain in memory. A temporary App Group inbox is explicitly allowed to bridge the share extension and app.

This plan narrows the broader [product specification](PRODUCT_SPEC.md). Do not implement a database, canvas restoration, account system, cloud sync, background jobs, background removal, image selection, multi-image galleries, price extraction, retailer adapters or a full import-inbox screen. Keep existing sample products and canvas interactions working. Do not rename unrelated models or redesign the availability pipeline.

Defaults are decisions for this prototype, not unresolved questions:

- One unique HTTP(S) link per share. Reject ambiguous shares containing multiple different links.
- A small extension preview with Add and Cancel; confirm only after the handoff succeeds.
- Processing starts in the main app, not the extension. The user manually opens Garms.
- Extract a page/product title and one representative image. Use that image directly, without a cutout.
- If extraction fails, retain the URL and retry action in the current session. A generated placeholder sticker makes the captured link visible on the canvas.
- Deduplicate exact normalized URLs within the session; preserve query parameters and fragments for now. Do not promise identity matching across shortened or tracking links.
- After consumption, the inbox is no longer a recovery store. Terminating Garms loses imported state by design.

## Relevant existing code

Paths below are relative to the repository root.

| File | Existing responsibility and intended change |
| --- | --- |
| `ios/Garms.xcodeproj/project.pbxproj` | One app target, synchronized `Garms` source group, iOS 26.2 deployment target. Add and embed the extension, shared source membership and entitlements. |
| `ios/Garms/App/garment_swiftApp.swift` and `ContentView.swift` | SwiftUI entry point and root. Avoid restructuring unless needed for stable session ownership. |
| `ios/Garms/Canvas/CanvasScreen.swift` | Owns `CanvasSession` in `@State`, starts availability work and observes scene phase. Add initial/foreground inbox draining and a compact import status UI. Its group thumbnails currently decode bundled files directly. |
| `ios/Garms/Canvas/CanvasSession.swift` | Owns document, viewport, camera, selection and explicit refresh. Add session-owned import state/assets and validated insertion/update methods. |
| `ios/Garms/Canvas/CanvasDocument.swift` | `SampleProduct`, `StickerPlacement`, validation, search and group totals. Make only the minimal model changes needed for imported items and unknown prices. |
| `ios/Garms/Canvas/CanvasFixtures.swift` | Builds and fits samples. Imported placements must be inserted after the initial fixture fit. |
| `ios/Garms/Canvas/CanvasAssetStore.swift` | Bundled image decoding, derived image cache and alpha masks. Add an in-memory source path while retaining bundled fallback. |
| `ios/Garms/Canvas/CanvasRenderer.swift` | Owns a `CanvasAssetStore`; rendering uses `product.asset` keys. Inject the session's image source and retain that interface. |
| `ios/Garms/Canvas/GarmsCanvasView.swift` | Owns renderer and gestures; connects render callbacks and memory warnings. Wire shared image sources here without changing gestures. |
| `ios/Garms/Canvas/CanvasImageDetails.swift` | Loads bundled artwork directly, displays a fixed price and repeats the image across five pages. Imported items need their actual single image and an unknown-price presentation. |
| `ios/Garms/Canvas/CanvasGeometry.swift` | Camera coordinate conversion and valid sticker-size limits. Use these when placing imports. |
| `ios/Garms/App/GarmsAPI.swift` | API base URL configuration, request validation and existing scrape call. Add a small import response/call using the same configuration. |
| `ios/Configuration/Debug-Info.plist` | Debug API address for simulator/physical device. No backend configuration is needed in the extension. |
| `web/lib/scrape.ts` and `web/app/api/scrape/route.ts` | Existing Firecrawl retrieval and availability classification. Reuse provider configuration/patterns without forcing import through the slow availability request. |
| `web/package.json`, `web/bun.lock` | Installed Firecrawl/Next versions and validation commands. Inspect installed types before using SDK fields. |
| `ios/tools/checks/` | Existing standalone Swift checks; extend this pattern or use a focused test target where UIKit is required. |

Read [web/AGENTS.md](../web/AGENTS.md) before backend work. It requires consulting the installed Next.js guides before writing framework code. Existing [README](../README.md) and [web README](../web/README.md) explain local API setup and checks. [Canvas implementation notes](CANVAS_IMPLEMENTATION_NOTES.md) describe the current canvas. Historical plans are context, not instructions to broaden this feature.

## Architecture

```text
Safari / retailer app
  -> Garms Share Extension
  -> App Group container: PendingImports/<UUID>.json
  -> Garms initial load / foreground activation
  -> in-memory import coordinator
  -> POST /api/import -> Firecrawl -> title + image URL
  -> bounded image download and decode
  -> CanvasSession -> product + placement + in-memory artwork
```

An extension is a separate process and does not share a Swift singleton or observable object with the app. Use Apple's shared-container mechanism. Do not build around responder-chain tricks, `UIApplication.shared`, or an assumption that `NSExtensionContext.open` launches the containing app from a Share Extension. See references 1–3 below.

## Step 1: Prove URL capture and handoff

Suggested new files:

- `ios/GarmsShare/ShareViewController.swift`
- `ios/GarmsShare/Info.plist`
- `ios/GarmsShare/GarmsShare.entitlements`
- `ios/Garms/Garms.entitlements`
- `ios/SharedImports/SharedImport.swift`
- `ios/SharedImports/SharedImportInbox.swift`

Create a Share Extension target named `GarmsShare`, display name Garms, embedded in the app. Use an extension bundle identifier under the existing app identifier, for example `f.garment-swift-2.share`. Use the same signing team and compatible deployment target as the app. Set extension-safe API enforcement. Ensure its Info.plist is not accidentally copied as a resource.

Enable the same App Group on both targets, with a single shared identifier constant, for example `group.f.garment-swift-2.imports` if available to the signing team. Configure development provisioning for both targets. An unsigned build validates compilation but does not prove device entitlements work. If account access is unavailable, finish compile-time work and report the exact device-signing step that remains.

Keep the Foundation-only shared files outside the synchronized app directory and explicitly include them in both targets. Do not accidentally compile the app entry point, canvas or API client into the extension.

Configure `com.apple.share-services` and activation rules for one web URL and text. Use `UTType.url` providers first; fall back to extracting an HTTP(S) link from plain text/extension text. Inspect all input items and attachments, but collapse repeated representations of the same URL. Use `NSItemProvider` asynchronously; never block the extension's main thread. Handle loading errors and cancellation. Do not require Safari JavaScript preprocessing or image attachments for this version.

Reject missing hosts, credentials, non-web schemes and oversized URLs (use the existing 4,096-character API limit). Preserve the submitted URL; normalization for deduplication should only trim whitespace and normalize scheme/host casing. Keep path, query and fragment intact. Test activation against actual host payloads; adding a permissive `TRUEPREDICATE` is not a finished solution.

Show the detected domain/link, Add and Cancel. Disable Add until parsing succeeds and while writing. After a successful write, show “Queued — open Garms to finish importing” with Done. Cancel before Add writes nothing; after a successful Add the item is already queued. Do not report “Added to canvas” from the extension.

### Inbox contract

Each JSON record contains `schemaVersion: 1`, UUID `id`, `url`, optional `suggestedTitle` and `createdAt`. No scraped content, artwork or canvas state belongs here.

- Resolve the directory with `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`; never hardcode its filesystem location.
- Write each UUID record atomically. Use a separate file per share rather than read-modify-write on a shared array, so simultaneous extension/app work cannot overwrite other shares.
- Readers only process completed `.json` records. Ignore temporary files.
- Expose small operations: enqueue, list/read, acknowledge/remove. Allow a directory override for local tests.
- Do not dismiss successfully if the App Group directory or write fails; show a retryable error.
- Isolate malformed records so one bad file cannot block later imports; remove only the offending file and report a concise error.

Milestone: share a Safari URL on a device, open Garms, and display that exact URL in memory. Prove this before adding extraction.

## Step 2: Consume into stable session state

Suggested new app file: `ios/Garms/Imports/ImportCoordinator.swift`. Keep one coordinator for the existing `CanvasSession` lifetime, not a new instance on each SwiftUI body evaluation. A session-owned observable coordinator is sufficient; avoid an app-wide architecture rewrite.

Call a coalesced drain on initial view task and each transition to `.active` in `CanvasScreen`. The existing scene handler currently only resolves interactions on inactivity. Preserve that behavior and the existing availability task.

Read each valid record, register its UUID and normalized URL in memory, then acknowledge its file. Acknowledge only after ownership has transferred to the in-memory coordinator. If removal fails, a later drain must not duplicate the UUID. New files written during a drain can wait for the next activation. Never delete the whole inbox directory after taking a snapshot.

Maintain minimal status per import: queued, processing, ready, failed with message. Process one item at a time. Keep failed records in memory for explicit Retry and Dismiss. Deduplicate both pending imports and products already placed in the current document; a duplicate ready item should select/reveal its existing placement. If its placement has been deleted, allow reimport instead of reporting an invisible duplicate.

Use an attempt identifier or cancellation token so a late result cannot recreate a dismissed/deleted item or overwrite a newer retry. Do not rely on a view task surviving backgrounding. Cancel/pause processing on inactivity and make interrupted work eligible when active again; do not claim background completion. Repeated activation must not start parallel drain/process loops.

Use a compact status row or small sheet reachable from the canvas: importing count, failed URL, Retry and Dismiss. No new navigation hierarchy. Unconsumed inbox files survive app termination; consumed items do not. Document this intentional prototype behavior in the README.

## Step 3: Add a minimal extraction endpoint

Suggested new files: `web/app/api/import/route.ts`, `web/lib/import-product.ts` and its focused tests. Add `GarmsAPI.importProduct(url:)` and a decodable result in `GarmsAPI.swift`.

Request: `POST /api/import` with `{ "url": "https://..." }`.

Response: `{ "url": "submitted URL", "title": "string or null", "imageURL": "absolute HTTPS URL or null" }`. Keep the original user URL as the product's source. Do not invent a canonical URL from an unverified redirect. No price, category or availability is required for this endpoint.

Use the existing server-side Firecrawl credentials and installed SDK. For the first implementation, inspect returned metadata for a suitable Open Graph title/image, falling back to page title. Confirm exact fields against the installed types and a real response. Firecrawl documents page metadata alongside scrape results (reference 7). Missing image metadata is an allowed partial result; do not take an arbitrary logo or recommended-product image from a page-wide image list.

Avoid introducing another LLM call, structured product schema or retailer-specific parser. Avoid calling the full existing `/api/scrape` route internally: that route waits for availability classification and its current cached response omits image metadata. If extracting a shared Firecrawl helper is useful, keep it small and preserve existing scrape behavior/tests.

Use the existing bounded JSON body and URL validation patterns. Keep provider secrets server-side, bounded provider timeouts, useful 4xx/5xx responses, and no automatic retry loop. Validate user destinations before submitting them: reject local/private literal addresses and localhost; avoid adding a direct unrestricted server-side fetch/redirect fallback. Keep import results uncached for this prototype; do not change the availability cache or database schema. Do not log full scraped pages or sensitive URL queries.

The iOS client uses the existing base URL/Debug configuration, displays understandable failures and preserves the queued URL. There is no backend call in the extension. Existing availability checking can remain independent; unknown availability must not prevent insertion or fade an item.

Milestone: a real public product page returns a usable title/image candidate; a page without an image returns a valid partial result.

## Step 4: Support in-memory artwork everywhere

Suggested new file: `ios/Garms/Imports/ImportedAssetLibrary.swift` (name is flexible).

Keep one session-owned mapping from unique asset keys to bounded encoded image data, including generated placeholder artwork. Keep `SampleProduct.asset` as a string key for now. Use a distinct UUID-based imported key so it cannot collide with a bundled name.

Introduce a common source resolver used by the renderer, product details and group thumbnails: look up imported data first; otherwise use existing bundled lookup. Add ImageIO decoding from `Data` alongside the existing URL decoder. Decode off the main thread, downsample and normalize orientation; return finite positive dimensions for aspect ratio.

The session library is the source of truth; the renderer's tier cache is disposable. Clearing `CanvasAssetStore` on memory warning must not permanently lose imported artwork. Inject the library through `GarmsCanvasView`/`CanvasRenderer` rather than placing the only copy inside a view-owned cache. Retain current tiering and alpha-mask hit testing. Invalidate cached tiers and masks if an asset is replaced, or issue a new asset key when replacing a placeholder.

Download images with an ephemeral URLSession so this feature does not introduce a disk-backed image cache. Set a finite timeout, validate success/content type and enforce a response byte limit while receiving data (suggested 10 MB); do not rely only on Content-Length. Accept HTTPS image URLs for this prototype, enforce that for redirects, and reject invalid data/oversized image dimensions before expensive decoding. Bound retained image size through downsampling/re-encoding (suggested longest edge 2,048 pixels). Missing or rejected images use a generated link placeholder, not broken bundle lookup.

For imported products, display a single image in details, not the current five repeated sample pages. Update both direct bundle decoding call sites in `CanvasImageDetails` and `CanvasGroupItemThumbnail`. Remove unused source data once no product references it; deleting one placement must not remove artwork still used by another.

## Step 5: Insert and update canvas items

Add a single session method for importing a product/asset and placement, and another for replacing its title/artwork after processing. Keep model mutations on the main actor.

Wait until `updateViewport` has completed its initial `CanvasFixtures.fit` before first insertion. Otherwise a fast response can be moved by sample layout or inserted against a zero viewport. After that, place near the current camera center in world coordinates, with an approximately 150-point longest edge adjusted for zoom and constrained by `CanvasConfiguration.edge`. A small deterministic offset for successive imports is enough; no packing algorithm.

Create a placeholder as soon as the queued link can be inserted. Use the submitted title or hostname, source URL, an empty/neutral category and generated placeholder asset. On successful processing, update that same product and placement, preserving center, stacking order and any user changes. Preserve its current longest edge when adjusting aspect ratio. If the user deletes it during the request, discard the result.

Before insertion resolve an active interaction using the existing callback. Update `document.products`, `placements` and `order` together; validate and roll back on failure. Call `refresh()` to rebuild spatial index, reconcile groups/search and render. Remember that `document` is `@ObservationIgnored`: also make sure an already-open details view sees asynchronous title/artwork changes through an observed revision or current-product lookup. Its current captured product value alone is insufficient.

Do not let `SampleProduct.price` report £250 for real imports. Make unknown price representable with fixture-compatible defaults, and show “Not available” for imports. Keep sample decoding and existing totals behavior for samples. Groups containing unknown prices should label their sum as a known-price subtotal, or omit the total when none are known; do not present a misleading complete total. Price extraction and currency conversion are out of scope.

If an active search would hide the newly added item, clear search when explicitly revealing the import. Do not reset the entire camera/layout or open product details automatically for every queued item.

## Step 6: Validate the actual flow

Write focused checks for behavior that crosses boundaries, using injected directories/API/image responses rather than live scraping in tests:

- URL extraction prefers URL attachments, falls back to text, rejects invalid/ambiguous payloads and collapses repeated representations. Preserve variant query parameters.
- Two atomic inbox writes survive; drain acknowledges only transferred records; malformed data and failed removal cannot duplicate or block all imports.
- Repeated activation produces one processor; retry is explicit; stale completions after delete/dismiss are ignored.
- Backend metadata normalization returns a nullable image, validates URLs and handles provider failure without breaking `/api/scrape`.
- Insertion waits for initial layout, preserves document validation, and updates one placeholder rather than adding a second placement.
- Imported artwork renders in canvas/details/group thumbnail and can be decoded again after clearing the derived cache.

Run from the repository root:

```sh
xcodebuild -project ios/Garms.xcodeproj -scheme Garms -destination 'generic/platform=iOS' -derivedDataPath /tmp/garms-ios-build CODE_SIGNING_ALLOWED=NO build
```

Ensure that command actually builds and embeds the new extension. Run relevant existing Swift checks using their established build approach; document the exact invocation for any added checks. From `web/`, run `bun test`, `bunx tsc --noEmit` and `bun run lint`; run `bun run build` when route integration/configuration changes warrant it. Do not claim signing or share-sheet success from a build alone.

Manual acceptance on a signed physical iPhone:

| Scenario | Expected result |
| --- | --- |
| Safari product page, Garms terminated | Garms appears in Share (possibly under More); Add queues; opening Garms creates one linked sticker and enriches its image/title. |
| Garms already running, switch to Safari and share | Returning to Garms drains the new item once. |
| Share two different products before opening | Both import sequentially; neither overwrites the other. |
| Share the same URL twice | One product/placement is reused within the session. |
| Cancel before Add | No queued record or canvas item. |
| Offline API / scrape failure | URL remains visible as a placeholder; Retry works when connectivity returns. |
| No image / corrupt image / oversized image | Placeholder and source URL remain usable; no crash or missing-bundle alert. |
| Delete while processing | Late response does not recreate the item. |
| Pan/zoom before import completes | Item remains at its chosen placement; existing items and camera are not reset. |
| Open details and group drawer | Imported image appears consistently; unknown price is not £250; source link opens correctly. |
| Clear derived image cache | Imported images can be recreated from session memory. |
| Force quit after consumption | Imported canvas items disappear, as agreed. Unconsumed handoffs still load. |
| Actual Vinted share | Verify real URL/text payload and activation separately from whether Firecrawl can extract that listing. Record limitations honestly. |

Use the physical-device API base URL instructions in the README; `localhost` on the phone is not the Mac. A Safari success is sufficient for the first end-to-end proof, but exercise Vinted early and report capture versus extraction results separately.

## Delivery expectations

Implement in small working increments: handoff, in-memory placeholder insertion, metadata extraction, image rendering, then retries and focused checks. Temporary stubs are acceptable between increments but not as the delivered end-to-end result.

Update README setup with the extension/App Group signing instructions, API configuration and explicit memory-only limitation. Include real tested host apps and any extraction failures. Avoid claiming support for all product sites. No persistence design or additional feature proposal is required to finish this task.

## External documentation

Checked 26 September 2026. Apple's archived extension guide remains useful for lifecycle/background context; check current SDK declarations for APIs and deployment availability during implementation.

1. [Apple: Understand How an App Extension Works](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionOverview.html) — process separation, lifecycle and containing-app communication constraints.
2. [Apple: Share Extensions](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Share.html) — extension target, input context, UI and completing a share request.
3. [Apple: Handling Common Scenarios](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/ExtensionScenarios.html) — shared containers and declaring supported content types.
4. [Apple: NSItemProvider](https://developer.apple.com/documentation/foundation/nsitemprovider) — asynchronous loading of shared attachments.
5. [Apple: NSExtensionActivationSupportsWebURLWithMaxCount](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension/nsextensionattributes/nsextensionactivationrule/nsextensionactivationsupportsweburlwithmaxcount) — web URL activation configuration.
6. [Apple: App Extension Keys](https://developer.apple.com/library/archive/documentation/General/Reference/InfoPlistKeyReference/Articles/AppExtensionKeys.html) — activation dictionary/predicate and extension-point keys.
7. [Firecrawl: Scrape API guide](https://www.firecrawl.dev/blog/mastering-firecrawl-scrape-endpoint) — scrape formats and metadata; installed SDK types take precedence for exact field names.

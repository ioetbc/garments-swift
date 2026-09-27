# Garms

One repository for the native SwiftUI clothing canvas app and the Next.js website/API. Each app has its own build and dependencies; no shared-package or monorepo tooling is required.

## Layout

```text
ios/
  Garms.xcodeproj/ Xcode project
  Garms/
    App/          App entry point and root view
    Canvas/       Canvas models, rendering, gestures and details
    Assets.xcassets/
    Samples/      Bundled sample products and images
  tools/          Fixture generator and standalone checks
web/              Next.js website and API routes
docs/             Product specification, research and feature plans
```

Open `ios/Garms.xcodeproj` in Xcode and select the `Garms` scheme. The bundle identifier remains `f.garment-swift-2` so the reorganized project retains the existing app identity.

## Build

Run from this repository's root:

```sh
xcodebuild -project ios/Garms.xcodeproj -scheme Garms -destination 'generic/platform=iOS' -derivedDataPath /tmp/garms-ios-build CODE_SIGNING_ALLOWED=NO build
```

## Website and API

Start the API from this repository's root:

```sh
cd web
bun install
bun run dev --hostname 0.0.0.0 --port 3000
```

`GET /api/health` returns `{"status":"ok","message":"Connected to Garms."}` with caching disabled. It is a public connectivity check and returns no user data or credentials.

Run the iOS app in the simulator using the Debug configuration, open any product's details drawer, then tap **Test connection**. It uses `http://localhost:3000` and displays the server's message or an error. The button is disabled during the request, which has a 10-second timeout.

For a physical iPhone, set `GARMS_API_BASE_URL` in `ios/Configuration/Debug-Info.plist` to your ngrok HTTPS URL, or `http://<your-Mac-hostname>.local:3000` on the same network (find the hostname in macOS Sharing settings). This value is bundled into Debug builds and works when opening the app directly from the phone. Rebuild after changing it, including when your ngrok URL changes. Keep the API server and tunnel running. Allow local network access when prompted. On a phone, `localhost` refers to the phone, not your Mac. Xcode’s **Edit Scheme → Run → Arguments → Environment Variables** can override `GARMS_API_BASE_URL`, but that override only applies to Xcode launches. The environment override and local-network transport exception apply only to Debug builds.

For Release builds, configure the target's `INFOPLIST_KEY_GARMS_API_BASE_URL` build setting with the deployed HTTPS origin. Until configured, the button reports that the server address is missing. Release builds require HTTPS and have no local-network transport exception. The Debug exception uses Apple's [NSAllowsLocalNetworking](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsallowslocalnetworking).

Server-only credentials belong in `web/.env.local` locally and the hosting provider's environment settings when deployed. Configure the website deployment's root directory as `web`. The prototype shared-link endpoint is described below.

## Documentation

- [Product specification](docs/PRODUCT_SPEC.md)
- [Current canvas implementation](docs/CANVAS_IMPLEMENTATION_NOTES.md)
- [Canvas research](docs/CANVAS_RESEARCH.md)
- [Historical canvas implementation plan](docs/CANVAS_IMPLEMENTATION_PLAN.md)
- [Live-link proposal](docs/LIVE_LINK_PLAN.md) — initial proposal; subsequent discussion favors evaluating Jev as the primary classifier in a Next.js backend.

## Canvas availability

When the canvas loads, the app checks each product independently through
`/api/scrape`, with at most three requests in flight. The server reuses successful
results for 24 hours. Products marked `out_of_stock`, `sold`, `listing_ended`, or
`removed` fade to 35% opacity and remain selectable. Unknown results and connection
failures do not mark products unavailable. Search dimming still takes precedence.
The drawer shows the loaded availability, and manual checks update that product’s canvas
availability, even when other products share its URL. VoiceOver reads the availability status too.

## Photo imports (prototype)

Open **Imports** and tap **Import photos**, select one or more images,
then tap **Add**. Each selected photo becomes a separate item in selection order.
Garms loads and normalises the image to at most 2,048 pixels, then runs the same
background removal and canvas flow as link imports. The original remains in
product details. Loading failures support Retry and Dismiss; background removal
failures retain the original and support **Retry background removal**. Processing
pauses while the app is inactive and resumes when it returns.

Photo imports use the system photo picker, need no API server, and have no listing
URL or availability check. As with link imports, items remain in session memory
and are lost when the app is terminated. Each photo's detected subjects stay
together in one sticker; selecting individual garments within a photo is not supported.

## Shared-link imports (prototype)

Share one HTTP(S) product link to **Garms**, tap **Add**, then **Done** and manually
open Garms. A link sticker appears after initial canvas layout; the app processes
imports sequentially while active. The Imports button shows progress and failed
links with Retry and Dismiss. Dismiss removes that imported sticker. Exact URLs
are deduplicated within the session, preserving size/variant queries and fragments.
A missing or rejected image leaves the linked placeholder available for retry.

After downloading the first photo, Garms immediately shows the original, downloads
the remaining gallery photos, then removes the first photo's background
with Apple's Vision foreground-instance request in the main app, off the UI thread.
All detected subjects stay together in one cropped transparent sticker. The original
is the orientation-normalised image bounded to 2,048 pixels, and remains available
beside the labelled Cutout in product details. Canvas and group thumbnails use the
cutout. Position, current longest edge and stacking order survive replacement.
The product drawer carousel shows the cutout, its original, and the remaining
listing photos in order. Secondary photos keep their backgrounds; failed secondary
downloads are logged and skipped without failing the import. Interrupted downloads
resume from the pending photo without duplicating photos already saved.

The Imports sheet shows “Removing background…” during extraction. If extraction
fails or finds no usable foreground, the original stays visible and the import
finishes Ready with “Background kept” and the specific reason. Inactivity pauses work; returning resumes
extraction from the original without repeating the download. All image assets live
in session memory, survive drawing-cache eviction, and are released when no product
references them. “Retry background removal” retries a retained original without
fetching the listing or downloading its image again. Garment-only extraction is not supported.
Vision internal inference errors get one retry using a supported GPU, with both
attempts recorded in the import log. Simulator logs identify the runtime explicitly;
if inference cannot initialise there, verify extraction on a physical iPhone.


The app and embedded `GarmsShare` extension both use App Group
`group.f.garment-swift-2.imports`. In Xcode, select your development team for both
targets, register/enable that App Group for `f.garment-swift-2` and
`f.garment-swift-2.share`, and refresh automatic development provisioning. If your
team needs different identifiers, update both entitlements and the single
`SharedLink.appGroup` constant together, plus both bundle identifiers. Install a
signed build on an iPhone; an unsigned build cannot validate App Group access or
Share Sheet activation. Garms may need enabling under the Share Sheet's **More**.

Configure `FIRECRAWL_API_KEY` in the server's environment. `POST /api/import`
returns the submitted URL, nullable title, nullable HTTPS `imageURL`, and an ordered,
deduplicated `imageURLs` gallery. `imageURL` remains the first entry for older clients.
Image selection prefers Open Graph metadata, then Twitter image metadata and raw
HTML social tags, with a first-listing-photo fallback for Vinted UK. Every candidate
must be an absolute public HTTPS URL without credentials; arbitrary page images
(such as avatars, logos and recommendations) are not used.
The gallery includes matching Product JSON-LD images and, for Vinted UK, the full
embedded listing photo array (including photos hidden behind “+ more”). If only a
social image is available, the gallery contains that single image.
For SSENSE, the importer uses rendered images matching the current product SKU,
orders them by photo number, and excludes the unexpanded `__IMAGE_PARAMS__` URL
in its structured data. Different sizes of the same photo appear only once.
It does not run availability classification or use the availability cache. Use
the physical-device API address instructions above; the extension needs no API
configuration. Imported prices are unknown, and group totals identify known-price
subtotals when needed.

**Memory only:** the inbox temporarily retains unconsumed URL handoffs. Once the
app takes ownership, it acknowledges the handoff; imported products, artwork,
failures and retries exist only in that app session. Force quitting loses consumed
imports. There is no canvas restoration or background completion.

Validation on 26 September 2026:

- Unsigned iOS build compiled and embedded `GarmsShare.appex`.
- All 15 backend tests, TypeScript, lint, and the webpack production build passed.
  The default Turbopack build was blocked by the environment's worker-port restriction.
- Shared URL/inbox, import session, availability, initial layout and search checks
  passed. `MagneticDragChecks.swift:86` fails “Cancellation must restore the document”
  on both the current tree and unmodified HEAD sources; this existing failure remains.
- Live Firecrawl extraction of the fixture Vinted UK listing returned “Next top | Vinted”
  and an `images1.vinted.net` image candidate. Allbirds Men's Tree Runner returned a
  title without an image; `example.com` returned a valid title-only partial result.
  These are extraction results, not proof of share capture or support for all listings.
- Physical-device Safari and Vinted share payloads, activation, provisioning and
  end-to-end image display still need the signed-device acceptance run in
  [the import plan](docs/SHARED_LINK_IMPORT_PLAN.md).

Run focused shared URL/inbox checks from the repository root:

```sh
xcrun swiftc -module-cache-path /tmp/garms-swift-modules ios/SharedImports/*.swift ios/tools/checks/SharedImportChecks.swift -o /tmp/garms-shared-checks
/tmp/garms-shared-checks
```

Run UIKit/session and existing canvas checks on an Apple Silicon Mac with Xcode
26.2 using a standalone Mac Catalyst executable:

```sh
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/ImportSessionChecks.swift
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/ForegroundCutoutChecks.swift
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/AvailabilityChecks.swift
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/InitialLayoutChecks.swift
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/SearchChecks.swift
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/MagneticDragChecks.swift
```

The import checks inject temporary inbox directories and API/image/cutout state; they
cover layout gating, deduplication, malformed records, failed acknowledgement,
pause/resume, explicit retries, stale results, geometry preservation and source
artwork surviving derived-cache clearing. Backend checks run with `cd web && bun test`;
also run `bunx tsc --noEmit`, `bun run lint` and `bun run build`. In environments
where Turbopack cannot bind its worker port, `bun run build --webpack` provides a
production route-integration check.

Background-removal validation (26 September 2026): `ImportSessionChecks`,
`ForegroundCutoutChecks`, `InitialLayoutChecks`, `SearchChecks` and
`AvailabilityChecks` passed, as did the unsigned iOS app/extension build using
`xcodebuild -project ios/Garms.xcodeproj -scheme Garms -destination 'generic/platform=iOS' -derivedDataPath /tmp/garms-ios-build CODE_SIGNING_ALLOWED=NO build`.
The magnetic-drag check still fails at its documented line 86 cancellation assertion.
The new checks cover original publication, successful replacement, fallback,
cancellation-insensitive extraction, resume without network repetition, late results
after deletion/dismissal, shared asset ownership, and alpha-aware hit testing.
They inject extraction results and do not establish Vision segmentation quality.

A signed Debug build also passed and was installed on the connected **iPhone 17 Pro,
iOS 26.6.2**. A temporary offline validation screen called the production worker on
bounded bundled images, then the normal app build was restored. Measured single-run
worker times (including decode/PNG encoding, excluding download) were:

| Case | Time | Output |
| --- | --- | --- |
| Person wearing a beige shirt | 0.257 s | 816 × 2,048 PNG |
| Red shoe | 0.137 s | 1,600 × 934 PNG |
| That cutout used as already-transparent input | 0.135 s | 1,600 × 934 PNG |
| Two separated copies of the shoe on white | 0.120 s | 1,520 × 897 PNG |

The retrieved outputs preserved the person, both separated shoes and the transparent
gap. They contained fully transparent and partially transparent pixels. Visual
inspection found some white edge halos from the source background; no border was
added by Garms. These four runs are smoke checks, not a performance benchmark.
Flat clothing and difficult backgrounds still need real-image coverage. Safari/Vinted
sharing, details updating while open, thumbnails, physical touch-through, pan/zoom
responsiveness and actual background/reactivation remain manual acceptance checks;
the relevant state/alpha boundaries were checked deterministically on Catalyst.

### Import diagnostics

Each Imports entry includes an expandable **Processing log** and **Copy log** button.
The copied report includes the product URL, import ID, timestamps, server Firecrawl
request ID, markdown length, metadata/image selection, image download/decode,
Vision background removal, canvas installation, retries and pause/resume events.
Failures retain their descriptions, domains, codes and underlying error details.
“Background kept” means the original was retained because no usable cutout could
be produced or installed; the warning now explains why. Logs remain in session
memory (up to 300 entries per import) and are also emitted to the iOS console.
Server extraction logs appear in the API terminal and are returned to the app on
success and failure. Server logs omit page contents and redact provider keys and
URLs in provider errors. Restart the API and rebuild the app for full diagnostics.

Use **Send log to Mac** on an import to send its current report to
`POST /api/import/diagnostics`. The terminal running the configured API server
prints it between `GARMS IMPORT LOG FROM PHONE` / `END GARMS IMPORT LOG` markers.
The app confirms delivery or displays the send error. This works through the same
API base URL/tunnel as product imports and does not depend on Universal Clipboard.
**Copy log** still copies locally on the phone. Reports include the product URL
and are sent only when you press the button (256 KB maximum).

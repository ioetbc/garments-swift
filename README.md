# Garms

One repository for the native SwiftUI clothing canvas app and its Convex backend. Each app has its own build and dependencies; no shared-package or monorepo tooling is required.

## Layout

```text
ios/
  Garms.xcodeproj/ Xcode project
  Garms/
    App/          App entry point and root view
    Canvas/       Canvas models, rendering, gestures and details
    Assets.xcassets/
  tools/          Standalone checks (their fixtures live in tools/checks/support)
web/              Convex backend
  convex/         Schema, per-User functions and tests
docs/             Product specification, research and feature plans
```

Open `ios/Garms.xcodeproj` in Xcode and select the `Garms` scheme. The bundle identifier remains `f.garment-swift-2` so the reorganized project retains the existing app identity.

## Build

Run from this repository's root:

```sh
xcodebuild -project ios/Garms.xcodeproj -scheme Garms -destination 'generic/platform=iOS' -derivedDataPath /tmp/garms-ios-build CODE_SIGNING_ALLOWED=NO build
```

Imports run as Convex actions (`web/convex/imports.ts`) for the signed-in User, so the app needs no API server or tunnel. Set `FIRECRAWL_API_KEY` and `AI_GATEWAY_API_KEY` on each Convex deployment (`npx convex env set`).

## Convex backend

Every Canvas, Product, Sticker and Group is stored in Convex and scoped to the User
from the auth identity (see `CONTEXT.md` and `docs/adr/0002`). Users sign in with email and password
through Clerk (`docs/adr/0001`); a request with no identity is always rejected. Each Convex
deployment is paired with one Clerk instance: dev ↔ Clerk development, prod ↔ Clerk production.
In each Clerk instance, enable Email (with password, verified by email code) as the only method, register the iOS app
as a native application, and activate the Convex integration.

```sh
cd web
npx convex env set CLERK_FRONTEND_API_URL https://<instance>.clerk.accounts.dev  # the paired Clerk instance
npx convex env set CLERK_SECRET_KEY sk_test_…  # lets deleting a User remove their Clerk user
npx convex env set AI_GATEWAY_API_KEY …  # reads the shop and title off an imported photo
npx convex dev                         # local or dev deployment; regenerates convex/_generated
bun run test                           # backend tests (convex-test, in memory)
bun run typecheck
```

The iOS app reads `CONVEX_URL` and `CLERK_PUBLISHABLE_KEY` from
`ios/Configuration/Debug-Info.plist` (Clerk development, Convex dev) or
`ios/Configuration/Release-Info.plist` (Clerk production, Convex prod). Debug builds can
override `CONVEX_URL` from the scheme environment (`http://127.0.0.1:3210` for a local
deployment in the simulator).
A new User starts with an empty Canvas holding only **Recent uploads**. Edits save when each
gesture ends; offline, the last loaded Canvas stays viewable and editing is disabled.

## Documentation

- [Product specification](docs/PRODUCT_SPEC.md)
- [Current canvas implementation](docs/CANVAS_IMPLEMENTATION_NOTES.md)
- [Canvas research](docs/CANVAS_RESEARCH.md)
- [Historical canvas implementation plan](docs/CANVAS_IMPLEMENTATION_PLAN.md)
- [Live-link proposal](docs/LIVE_LINK_PLAN.md) — initial proposal; subsequent discussion favors evaluating Jev as the primary classifier in a Next.js backend.

## Notes

Product and group drawers include a multiline **Notes** field. Edits save as you
type, support undo/redo, and are stored with the Product or Group in Convex.

## Photo imports (prototype)

Open **Imports** and tap **Import photos**, select one or more images,
then tap **Add**. Each selected photo becomes a separate item in selection order.
Garms loads and normalises the image to at most 2,048 pixels, then runs the same
background removal and canvas flow as link imports. The original remains in
product details. Loading failures support Retry and Dismiss; background removal
failures retain the original and support **Retry background removal**.

Photo imports use the system photo picker and need no API server. Once a photo's Sticker
is on the Canvas, the whole photo, flattened onto white, is sent to the `matches:search`
Convex action. A vision model behind the AI Gateway reads the shop, its website and the
product title off it, then Firecrawl searches that title on the shop's site (signed-in
Users only). The listing found is imported straight away through the `imports:product`
action, exactly like a shared link, keeping the photo as the Cutout and first Photo. When
nothing is found the Product stays as imported, with no link; a failed listing import shows
in the Imports sheet with Retry. As with link imports, items remain in session memory
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
finishes Ready with “Background kept” and the specific reason. All image assets live
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

Configure `FIRECRAWL_API_KEY` on the Convex deployment. The `imports:product` action
returns the submitted URL, nullable title, nullable HTTPS `imageURL`, and an ordered,
deduplicated `imageURLs` gallery and a nullable Price. `imageURL` is the gallery's first entry.
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
The extension needs no server configuration. Imported prices are unknown, and group totals identify known-price
subtotals when needed.

**Memory only:** the inbox temporarily retains unconsumed URL handoffs. Once the
app takes ownership, it acknowledges the handoff; imported products, artwork,
failures and retries exist only in that app session. Force quitting loses consumed
imports. There is no canvas restoration or background completion.

Validation on 26 September 2026:

- Unsigned iOS build compiled and embedded `GarmsShare.appex`.
- All 15 backend tests, TypeScript, lint, and the webpack production build passed.
  The default Turbopack build was blocked by the environment's worker-port restriction.
- Shared URL/inbox, import session, initial layout and search checks
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
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/InitialLayoutChecks.swift
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/SearchChecks.swift
zsh ios/tools/checks/run-canvas-check.sh ios/tools/checks/MagneticDragChecks.swift
```

The import checks inject temporary inbox directories and API/image/cutout state; they
cover layout gating, deduplication, malformed records, failed acknowledgement,
explicit retries, stale results, geometry preservation and source
artwork surviving derived-cache clearing. Backend checks run with `cd web && bun run test`
and `bun run typecheck`.

Background-removal validation (26 September 2026): `ImportSessionChecks`,
`ForegroundCutoutChecks`, `InitialLayoutChecks`, `SearchChecks` and
`AvailabilityChecks` passed, as did the unsigned iOS app/extension build using
`xcodebuild -project ios/Garms.xcodeproj -scheme Garms -destination 'generic/platform=iOS' -derivedDataPath /tmp/garms-ios-build CODE_SIGNING_ALLOWED=NO build`.
The magnetic-drag check still fails at its documented line 86 cancellation assertion.
The new checks cover original publication, successful replacement, fallback,
late results
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

Each import step is logged to the iOS console (subsystem `f.garment-swift-2`, category
`Import`). Failures shown in the Imports sheet keep their descriptions, domains, codes and
underlying error details. “Background kept” means the original was retained because no
usable cutout could be produced or installed; the note explains why.
Server-side scrape and extraction steps (`Product import: …`) appear in the Convex
dashboard logs; they omit page contents.

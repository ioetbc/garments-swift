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

Server-only credentials belong in `web/.env.local` locally and the hosting provider's environment settings when deployed. Configure the website deployment's root directory as `web`. The live-link backend is still future work.

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

# Garms

One repository for the native SwiftUI clothing canvas app and the future Next.js website/API. Each app has its own build and dependencies; no shared-package or monorepo tooling is required.

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
web/              Next.js installation location (currently empty)
docs/             Product specification, research and feature plans
```

Open `ios/Garms.xcodeproj` in Xcode and select the `Garms` scheme. The bundle identifier remains `f.garment-swift-2` so the reorganized project retains the existing app identity.

## Build

Run from this repository's root:

```sh
xcodebuild -project ios/Garms.xcodeproj -scheme Garms -destination 'generic/platform=iOS' -derivedDataPath /tmp/garms-ios-build CODE_SIGNING_ALLOWED=NO build
```

## Website and API

Install Next.js inside `web/` from this repository's root:

```sh
cd web
npx create-next-app@latest . --disable-git
```

Use the existing root Git repository; do not initialize another repository inside `web/`. The empty directory will become tracked once Next.js creates files in it.

The apps will communicate over HTTPS. Server-only credentials belong in `web/.env.local` locally and the hosting provider's environment settings when deployed. Configure the website deployment's root directory as `web`. No Next.js project or live-link backend has been created yet.

## Documentation

- [Product specification](docs/PRODUCT_SPEC.md)
- [Current canvas implementation](docs/CANVAS_IMPLEMENTATION_NOTES.md)
- [Canvas research](docs/CANVAS_RESEARCH.md)
- [Historical canvas implementation plan](docs/CANVAS_IMPLEMENTATION_PLAN.md)
- [Live-link proposal](docs/LIVE_LINK_PLAN.md) — initial proposal; subsequent discussion favors evaluating Jev as the primary classifier in a Next.js backend.

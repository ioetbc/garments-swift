# Live links: proposed product and implementation plan

Status: proposal for discussion, not an implemented or agreed specification.
Research date: 25 September 2026.

## Recommendation

Start with a small, explicitly supported set of platforms and a common availability model. Use official APIs where access permits, then product-specific structured data and tested page adapters where permitted. Consider AI only as a later fallback for ambiguous content that was successfully retrieved.

The product promise is: “We check supported links when you open Garms and show when a saved listing is no longer available.” This is a periodically checked link, not a guarantee of live inventory or a reserved purchase.

Accepting a URL and supporting automatic monitoring are separate capabilities. An unsupported URL can still be saved and imported where possible, with “Automatic availability checks not supported” in its details.

## User experience

- Import retains the source URL, original images and metadata even when checking fails.
- On launch and return to the foreground, show the saved canvas immediately and request refreshes for eligible links. Display existing results while checks run.
- Confirmed unavailable products fade to a proposed 45% opacity, with a compact availability label. The label remains readable independently of image opacity. Validate this value visually.
- Distinguish “Sold”, “Out of stock”, “Listing ended”, and “Listing unavailable”. Do not call every unavailable listing sold.
- Keep faded items selectable, movable and usable in outfits. Never remove an item automatically.
- Product details show the original link, availability, last successful check, any current check problem, “Check again”, and a per-product monitoring toggle.
- Availability applies to all placements of the product. It is separate from ownership: the user owning or selling a garment is unrelated to the source listing being sold.
- Proposed default: fade only products the user is considering buying (the current prototype calls this Wishlist). Owned, Ordered and other personal statuses retain normal canvas appearance, with source availability still visible in details. Confirm this product choice before implementation.
- Confirmed restocks restore normal appearance. Sold is not permanently terminal: listings can be renewed or corrected.
- An offline or blocked check does not newly fade an item or restore a previously unavailable item. Keep its last confirmed state, explicitly qualified as last known if stale; with no previous result, show unknown and keep normal appearance.
- Include availability and staleness in accessibility labels; opacity alone must not carry the meaning.

## Availability and check health are separate

| Availability | Meaning | Canvas treatment for a tracked purchase |
| --- | --- | --- |
| available | Evidence this exact listing/offer is purchasable | Normal |
| sold | Explicit evidence it sold | Faded, Sold |
| outOfStock | Explicit evidence stock is exhausted | Faded, Out of stock |
| ended | Listing/auction ended; sale not established | Faded, Listing ended |
| unavailable | Confirmed removed/missing or otherwise not purchasable; cause unspecified | Faded, Listing unavailable |
| unknown | No reliable availability evidence yet | Normal, status in details |

Store check health independently: idle, checking, succeeded, failed, blocked, unsupported. Derive freshness from timestamps and policy. Unknown observations never overwrite confirmed availability.

Reserved, preorder, backorder, regional restrictions and variant-specific availability must not be silently collapsed into sold. Initially, retain an explanatory reason and abstain where an adapter cannot establish whether the saved offer can be purchased. Extend the enum when these states receive deliberate UX support.

## Evidence policy

1. Match the exact listing ID, offer and any selected variant before interpreting availability.
2. Prefer a supported official API field that describes this listing. Check expiry/end dates as well as inventory where required.
3. Use product/offer structured data (for example JSON-LD availability), scoped to the matching product. Never use availability from recommendations elsewhere on the page.
4. Use a versioned platform adapter for documented, fixture-tested page signals, including locale and page type. Require positive evidence of availability as well as unavailability; absence of a Sold badge is not evidence of stock.
5. Conflicting or incomplete signals produce an inconclusive check, not a guessed transition. A provider adapter defines its source precedence using validated fixtures.

HTTP handling:

- 200 only means a response arrived. It might contain a sold listing, login page, consent screen, challenge or soft 404.
- 404/410 are evidence the requested resource is missing, not evidence of a sale. First exclude bad URL normalization, locale routing and access/challenge responses. For generic HTTP evidence, require a second independent successful retrieval showing the same missing-resource result before promoting to unavailable. An authoritative provider response may be sufficient immediately.
- 401/403, CAPTCHA, rate limits, timeouts, offline failures and 5xx are check problems. Preserve last confirmed availability, back off and retry later.
- Validate redirects against listing identity. A redirect to search, the home page, or a similar/relisted product must not establish the original item's availability.

Store the evidence source, adapter version, reason code, observation timestamp and a bounded diagnostic excerpt or hash where permitted. Do not retain whole pages by default. AI self-reported confidence is not sufficient evidence to fade a product.

## Platform feasibility before committing the launch list

The candidate list is eBay, Etsy and Vinted, but each needs an access and correctness spike before it is advertised as supported. Validate against real, permitted examples in the target market, initially UK/English.

- **eBay:** official Browse documentation recommends checking `itemEndDate` and `estimatedAvailabilityStatus`. Use a listing identifier rather than assuming sold listings return 404. Verify production eligibility, auction handling, variation identifiers and behavior for ended or missing items using the credentials available to this app. See [Browse API](https://developer.ebay.com/api-docs/buy/api-browse.html) and [production requirements](https://developer.ebay.com/api-docs/buy/buy-requirements.html).
- **Etsy:** documented states include active, inactive, sold_out and expired. Confirm that the approved API access can read the required fields for arbitrary saved listings, including inactive ones; the existence of a state in the API does not establish access for this use case. See [listing definitions](https://developers.etsy.com/documentation/essentials/definitions/) and [API terms](https://www.etsy.com/uk/legal/api/). Etsy's published terms constrain automated scraping, so do not assume HTML scraping is an available fallback.
- **Vinted:** a sold badge is a candidate signal to investigate, not a verified contract. The published [Vinted terms](https://www.vinted.com/terms-and-conditions) restrict external automation unless allowed. Verify the applicable UK access route and authorization; no reliable permitted integration has been established by this research. Until then, support saving the URL without promising live checks.
- **Other retailers:** [Schema.org ItemAvailability](https://schema.org/ItemAvailability) provides reusable vocabulary. It does not guarantee a page publishes accurate, current or variant-specific data. Add support only after evaluating matching and correctness.

## Architecture

Prefer a small backend service for checks. Provider credentials remain on the server, parsers can be repaired without an app release, and shared checks reduce duplicate requests. The iOS app owns presentation and offline cached results. This repo currently has no live-link service; backend hosting, persistence and authentication are implementation choices still to make.

Proposed flow:

1. Import URL, preserve the original, resolve/validate its provider and listing identity, and save the product independently of check success.
2. Associate it with a monitored listing/offer key containing provider, listing ID, variant if known, and relevant market context. Preserve meaningful query parameters; strip only known tracking parameters.
3. On cold launch and foreground activation, submit a bounded batch of product references to a refresh endpoint. The server returns cached results and queues due checks.
4. Worker selects the provider adapter, obtains evidence, applies the transition policy and saves a monotonically versioned result.
5. While foregrounded, the app receives results through bounded polling or a stream. On the next activation it fetches any missed changes.
6. Merge only newer results for the still-current source revision. Ignore responses for deleted products or replaced URLs. Update every placement and the open details view without disturbing gestures or layout.

Illustrative boundaries: `LiveLinkService` in Swift; backend `ListingResolver`, `ProviderAdapter`, `AvailabilityPolicy`, scheduler/cache, and result store. Share extraction of listing identity between URL import and monitoring; import failure must not prevent saving the link.

Backend responsibilities include authenticated access to user records, per-domain rate limits, bounded concurrency, request coalescing, retry backoff, response-size/time limits, and a provider disable switch. Treat imported URLs as untrusted: limit schemes and ports, reject private/loopback/link-local destinations after DNS resolution and on every redirect, and restrict browser subrequests if rendering is introduced. Share cached results only for identical public offers and market context; never share user credentials or private URLs across users.

## Proposed refresh defaults

- Every app opening triggers a freshness evaluation, not necessarily a new request to every retailer.
- Initial import checks immediately where supported. Available one-off listings become due after 15 minutes; ordinary retail offers after 60 minutes. These are starting values to validate against provider quotas and observed cost.
- Keep unavailable one-offs eligible for a slower daily recheck; out-of-stock retail offers can retain hourly eligibility to detect restocks.
- The defaults describe eligibility on app use, not continuous background monitoring while the app is closed. Push alerts and continuous monitoring are separate future scope.
- Prioritize visible/inspected products, then the remaining tracked products in bounded batches.
- Coalesce repeated app activations and duplicate product placements. Respect server freshness and provider Retry-After even for manual refresh; report when another check can run.
- Keep `lastAttemptedAt` separate from `lastConfirmedAt`. A failed request never advances the successful-check time.
- Mark old results stale when their freshness window expires. Details say “Last known: Sold · checked …” if a fresh check cannot be completed.

## Persistent model and Swift integration

Proposed product-level reference: original URL, resolved canonical URL, provider, external listing ID, optional offer/variant, market, trackingEnabled, and sourceRevision. Proposed availability snapshot: state, reason, lastConfirmedAt, lastAttemptedAt, checkHealth, nextCheckAt, observationVersion and evidenceSource. Keep rich diagnostics on the server.

Current code findings:

- `CanvasDocument.swift` holds `SampleProduct` and placements reference `productID`, so one product-level live-link snapshot naturally serves multiple stickers. Introduce a real persisted product record as the URL import foundation, with explicit migration/defaults for existing documents.
- `CanvasDocument.validate()` currently only accepts schema version 1. Any version change needs a migration rather than just incrementing that value. Older fixture products without links remain valid and unmonitored.
- `CanvasScreen.swift` stores personal statuses by placement only for the current session. Move ownership to the persistent product model as specified in PRODUCT_SPEC before coupling its display policy to availability. Reconcile the prototype's Wishlist/Sold/etc. menu with the specification's Considering/Owned/Ordered/Returned choices separately.
- `CanvasScreen.swift` already observes scene phase. Add initial-load refresh as well as transition-to-active refresh, with coalescing; do not depend solely on a phase change firing at launch.
- `CanvasRenderer.swift` already sets opacity for search. Define one combined style policy: proposed search non-match opacity 0.1 takes precedence; otherwise unavailable purchase opacity 0.45; otherwise 1. Avoid multiplying the two into near invisibility. Reset the full style on reused layers.
- `CanvasSession.document` is observation-ignored and rendering is explicitly triggered. Availability updates need an explicit render invalidation and an observable details snapshot; mutating a dictionary alone will not guarantee the drawer refreshes. Do not rebuild spatial indexes for availability-only changes.
- `CanvasImageDetails.swift` currently uses a placeholder URL. Replace it with the saved source and show independent availability and personal status rows.

Retail variants are an explicit boundary: without a selected size/colour, track listing-level availability and say so. Do not infer a desired size from notes. Exact-size stock tracking requires adding variant selection to import/details, despite structured size currently being out of product scope.

## AI later

AI could interpret an unfamiliar sold message or changed layout after a page is fetched. It cannot make inaccessible data available or establish that all URLs are supported.

If added, use it only after deterministic extraction is inconclusive, only on permitted content, and initially in shadow mode with no user-visible state changes. Supply bounded product-scoped evidence, require a structured answer tied to listing identity and cited page text, treat page instructions as untrusted data, and allow abstention. Enforce time/cost budgets and cache against content hash. Keep it only if evaluation shows better coverage without unacceptable false-unavailable decisions; do not treat repeated guesses as independent confirmation.

## Delivery sequence and verification

1. **Feasibility spike:** establish permitted access and capture representative available, sold, ended, missing, blocked, redirected and variant-specific examples for each candidate provider. Deliver a support matrix and measured check cost/latency. Select the first viable provider, provisionally eBay.
2. **Foundation and mocked UX:** persistent source/ownership/snapshot models and migrations; fade/labels/details; lifecycle refresh coordinator; fake adapter driving all states. This can be reviewed before any production integration.
3. **One provider end to end:** deploy the minimal service, integrate approved access, implement evidence/transition policy, offline cache, deduplication, retries and a disable switch. Release behind a feature flag to a small group.
4. **Broaden deliberately:** Etsy or another feasible provider, then permitted structured-data adapters. Add Vinted only when the spike establishes a sustainable access route. Evaluate AI separately after collecting real adapter failures.

Acceptance scenarios:

- An explicit sold result fades every eligible placement and updates an already-open details drawer.
- A sold source listing does not change the user's ownership status or erase any saved assets.
- Timeouts, challenges, 403/429 and outages never create a sold/unavailable transition.
- A single generic 404 remains unconfirmed; a validated repeated missing result becomes unavailable, not sold.
- Available recommendations cannot overwrite a sold primary listing; conflicting evidence causes abstention.
- Restock restores appearance; unknown/failed checks preserve last known state with honest timestamps.
- Repeated launches and duplicate placements do not multiply provider calls; out-of-order results cannot overwrite newer state.
- Offline launch is immediate; app interruption leaves durable work recoverable on the next opening.
- Search dimming, pooled layers, selection, drag animations and accessibility remain correct.
- Old documents still load; link replacement/deletion rejects in-flight results for the previous source.
- Tests cover supported locales, regional offers, variants and expired auctions without equating ended with sold.

Before launch, evaluate labelled fixtures and permitted live samples per provider, reporting false-unavailable decisions separately from unknown coverage and missed changes. Require all critical cases above to pass, investigate every false-unavailable fixture result, and set quantitative rollout targets using spike measurements. Monitor blocked/unknown rates, freshness, latency and cost; a sudden parser failure should pause that provider's transitions rather than mark its entire catalogue unavailable.

## Product choices still to settle

- Fade only items being considered for purchase (recommended), or all items regardless of personal status?
- Is listing-level stock sufficient initially, with exact size/colour monitoring deferred (recommended)?
- Accept cached results on frequent reopens (recommended), or request a fresh check each time subject to provider limits?
- Which platforms qualify for the first release after the access spike, and which remain save-only?

This plan changes no app behavior. Implementation should follow after these defaults and the first supported provider are settled.

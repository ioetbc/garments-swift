import { Context, Effect, Layer } from "effect";
import type { Candidate } from "../validators";
import { Auth } from "./auth";
import { InvalidInput, NotSignedIn, SearchFailed } from "./errors";
import { ListingSearch, type SearchResult } from "./listing.client";
import { ScreenshotReader } from "./screenshot.client";

// About 3 MB of image; the client sends a JPEG of at most 1024px, well under this.
const MAX_IMAGE_LENGTH = 4_000_000;
// ponytail: hand-maintained; if junk gets through, check candidates for structured-data product pricing instead.
const BLOCKED = new Set(["pinterest", "reddit", "google", "instagram", "tiktok", "twitter", "facebook", "tumblr", "wikipedia"]);
const blocked = (host: string) =>
  host === "x.com" || host.endsWith(".x.com") || host.split(".").slice(0, -1).some((label) => BLOCKED.has(label));

/** A search result as a Candidate match, unless it is a social or other non-shop site. */
export function candidateFrom(result: SearchResult | undefined): Candidate | null {
  const host = result && URL.parse(result.url)?.hostname.toLowerCase();
  if (!result || !host || blocked(host)) return null;
  const title = result.title?.trim();
  return { url: result.url, ...(title ? { title } : {}), domain: host.replace(/^www\./, "") };
}

/** Finding the listing a Screenshot came from. */
export class MatchService extends Context.Service<MatchService, {
  /**
   * The Candidate match for a base64-encoded JPEG Screenshot, or null, searched from the
   * caller's region (ISO 3166 alpha-2) when given.
   * Costs one vision model call and one web search; no page is scraped.
   */
  search(image: string, region?: string): Effect.Effect<Candidate | null, NotSignedIn | InvalidInput | SearchFailed>;
}>()("garms/MatchService") {
  static readonly layer = Layer.effect(MatchService, Effect.gen(function* () {
    const auth = yield* Auth;
    const reader = yield* ScreenshotReader;
    const listings = yield* ListingSearch;

    const search = Effect.fn("MatchService.search")(function* (image: string, region?: string) {
      yield* auth.token;
      if (!image || image.length > MAX_IMAGE_LENGTH) return yield* new InvalidInput({ message: "The Screenshot image is missing or too large." });
      if (region !== undefined && !/^[A-Z]{2}$/.test(region)) return yield* new InvalidInput({ message: "The region must be a two-letter country code." });
      // One line per step, so a bad match can be traced in the deployment's logs.
      const log = (step: string, details: object) => Effect.sync(() => console.info(`Screenshot search: ${step}`, JSON.stringify(details)));
      let started = Date.now();
      const listing = yield* reader.read(image);
      const query = listing.title && (listing.domain ? `${listing.title} site:${listing.domain}` : listing.title);
      yield* log("read", { ...listing, query, ms: Date.now() - started, imageLength: image.length });
      if (!query) return null;
      started = Date.now();
      const result = yield* listings.search(query, region);
      const candidate = candidateFrom(result);
      yield* log("searched", { result: result?.url, candidate: candidate?.url, region, ms: Date.now() - started });
      return candidate;
    });

    return MatchService.of({ search });
  }));
}

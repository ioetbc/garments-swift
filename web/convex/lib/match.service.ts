import { Context, Effect, Layer } from "effect";
import { internal } from "../_generated/api";
import type { ActionCtx } from "../_generated/server";
import type { Candidate } from "../validators";
import { Auth } from "./auth";
import { InvalidInput, NotSignedIn, SearchFailed, SearchLimited } from "./errors";
import { MAX_CANDIDATES } from "./product.service";
import { ListingSearch, type SearchResult } from "./listing.client";
import { ScreenshotReader } from "./screenshot.client";

// About 3 MB of image; the client sends a JPEG of at most 1024px, well under this.
const MAX_IMAGE_LENGTH = 4_000_000;

// ponytail: hand-maintained; if junk gets through, check candidates for structured-data product pricing instead.
const BLOCKED = new Set(["pinterest", "reddit", "google", "instagram", "tiktok", "twitter", "facebook", "tumblr", "wikipedia"]);
const blocked = (host: string) =>
  host === "x.com" || host.endsWith(".x.com") || host.split(".").slice(0, -1).some((label) => BLOCKED.has(label));

/** Counts one search against the caller's daily limit, in its own transaction. */
export class SearchQuota extends Context.Service<SearchQuota, {
  /** False once today's searches are used up. */
  claim(token: string): Effect.Effect<boolean>;
}>()("garms/SearchQuota") {
  static layer = (ctx: ActionCtx) => Layer.succeed(SearchQuota, SearchQuota.of({
    claim: (tokenIdentifier) => Effect.promise((): Promise<boolean> => ctx.runMutation(internal.matches.claim, { tokenIdentifier })),
  }));
}

/** Search results as Candidate matches, in the search engine's order, without social and other non-shop sites. */
export function candidatesFrom(results: ReadonlyArray<SearchResult>): Array<Candidate> {
  return results.flatMap(({ url, title }) => {
    const host = URL.parse(url)?.hostname.toLowerCase();
    return host && !blocked(host) ? [{ url, ...(title?.trim() ? { title: title.trim() } : {}), domain: host.replace(/^www\./, "") }] : [];
  }).slice(0, MAX_CANDIDATES);
}

/** Finding the listing a Screenshot came from. */
export class MatchService extends Context.Service<MatchService, {
  /**
   * Up to five Candidate matches for a base64-encoded JPEG Screenshot, searched from the
   * caller's region (ISO 3166 alpha-2) when given.
   * Costs one vision model call and one web search, counted against the caller's daily limit; no page is scraped.
   */
  search(image: string, region?: string): Effect.Effect<Array<Candidate>, NotSignedIn | InvalidInput | SearchLimited | SearchFailed>;
}>()("garms/MatchService") {
  static readonly layer = Layer.effect(MatchService, Effect.gen(function* () {
    const auth = yield* Auth;
    const quota = yield* SearchQuota;
    const reader = yield* ScreenshotReader;
    const listings = yield* ListingSearch;

    const search = Effect.fn("MatchService.search")(function* (image: string, region?: string) {
      const token = yield* auth.token;
      if (!image || image.length > MAX_IMAGE_LENGTH) return yield* new InvalidInput({ message: "The Screenshot image is missing or too large." });
      if (region !== undefined && !/^[A-Z]{2}$/.test(region)) return yield* new InvalidInput({ message: "The region must be a two-letter country code." });
      if (!(yield* quota.claim(token))) return yield* new SearchLimited();
      // One line per step, so a bad match can be traced in the deployment's logs.
      const log = (step: string, details: object) => Effect.sync(() => console.info(`Screenshot search: ${step}`, JSON.stringify(details)));
      let started = Date.now();
      const listing = yield* reader.read(image);
      const query = listing.title && (listing.domain ? `${listing.title} site:${listing.domain}` : listing.title);
      yield* log("read", { ...listing, query, ms: Date.now() - started, imageLength: image.length });
      if (!query) return [];
      started = Date.now();
      const results = yield* listings.search(query, region);
      const candidates = candidatesFrom(results);
      yield* log("searched", { results: results.map((r) => r.url), candidates: candidates.map((c) => c.url), region, ms: Date.now() - started });
      return candidates;
    });

    return MatchService.of({ search });
  }));
}

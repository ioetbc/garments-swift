import { Context, Effect, Layer } from "effect";
import { SearchFailed } from "./errors";

/** One web search result. */
export type SearchResult = {
  readonly url: string;
  readonly title?: string;
};

/** Firecrawl web search. One call per search. */
export class ListingSearch extends Context.Service<ListingSearch, {
  /**
   * The top page matching a query, which may use operators such as `site:`, geo-targeted to
   * a country (ISO 3166 alpha-2) when given.
   */
  search(query: string, country: string | undefined): Effect.Effect<SearchResult | undefined, SearchFailed>;
}>()("garms/ListingSearch") {
  static readonly layer = Layer.sync(ListingSearch, () => ListingSearch.of({
    search: (query, country) => Effect.tryPromise({
      try: async () => {
        const response = await fetch("https://api.firecrawl.dev/v2/search", {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${process.env.FIRECRAWL_API_KEY ?? ""}` },
          body: JSON.stringify({ query, limit: 1, sources: ["web"], ...(country ? { country } : {}) }),
        });
        if (!response.ok) throw new Error(`Firecrawl HTTP ${response.status}: ${(await response.text()).slice(0, 500)}`);
        const body = await response.json() as { success?: boolean; error?: unknown; data?: { web?: SearchResult[] } };
        if (!body.success) throw new Error(`Firecrawl search failed: ${String(body.error)}`);
        return body.data?.web?.[0];
      },
      catch: (cause) => new SearchFailed({ cause }),
    }).pipe(
      // The User only sees a generic message; the logs keep Firecrawl's reason.
      Effect.tapError((error) => Effect.sync(() => console.error("Screenshot search: Firecrawl search failed", error.cause))),
    ),
  }));
}

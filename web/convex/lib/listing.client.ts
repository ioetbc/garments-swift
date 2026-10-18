import { Context, Effect, Layer } from "effect";
import { SearchFailed } from "./errors";

/** One web search result, in the search engine's order. */
export type SearchResult = {
  readonly url: string;
  readonly title?: string;
};

/** Firecrawl web search. One call per search. */
export class ListingSearch extends Context.Service<ListingSearch, {
  /**
   * Up to ten pages matching a query, which may use operators such as `site:`, geo-targeted to
   * a country (ISO 3166 alpha-2) when given.
   */
  search(query: string, country: string | undefined): Effect.Effect<ReadonlyArray<SearchResult>, SearchFailed>;
}>()("garms/ListingSearch") {
  static readonly layer = Layer.sync(ListingSearch, () => ListingSearch.of({
    search: (query, country) => Effect.tryPromise({
      try: async (): Promise<{ results: ReadonlyArray<SearchResult> } | { failure: unknown }> => {
        console.log('what is the query', query)
        const response = await fetch("https://api.firecrawl.dev/v2/search", {
          method: "POST",
          headers: { "Content-Type": "application/json", Authorization: `Bearer ${process.env.FIRECRAWL_API_KEY ?? ""}` },
          body: JSON.stringify({ query, limit: 1, sources: ["web"], ...(country ? { country } : {}) }),
        });
        if (!response.ok) return { failure: `Firecrawl HTTP ${response.status}: ${(await response.text()).slice(0, 500)}` };
        const body = await response.json() as { success?: boolean; error?: unknown; data?: { web?: SearchResult[] } };
        if (!body.success) return { failure: body.error ?? "Firecrawl search failed" };
        return { results: body.data?.web ?? [] };
      },
      catch: (cause) => new SearchFailed({ cause }),
    }).pipe(
      Effect.flatMap((result) => "results" in result ? Effect.succeed(result.results) : Effect.fail(new SearchFailed({ cause: result.failure }))),
      // The User only sees a generic message; the logs keep Firecrawl's reason.
      Effect.tapError((error) => Effect.sync(() => console.error("Screenshot search: Firecrawl search failed", error.cause))),
    ),
  }));
}

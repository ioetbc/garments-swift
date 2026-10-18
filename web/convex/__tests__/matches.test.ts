import { convexTest } from "convex-test";
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { api } from "../_generated/api";
import schema from "../schema";
import { modules } from "../test.setup";

const alice = { tokenIdentifier: "test|alice" };
const image = btoa("cropped screenshot");

type Read = { shop?: string | null; domain?: string | null; title?: string | null };
type Result = { url: string; title?: string };

/** Stands in for the AI Gateway reading the Screenshot as `read`, and Firecrawl answering every search with `results`. */
function stub(read: Read, results: Result[] = [], status = { gateway: 200, firecrawl: 200 }) {
  const fetch = vi.fn<(url: string, init?: RequestInit) => Promise<Response>>(async (url) => url.startsWith("https://ai-gateway.vercel.sh/")
    ? Response.json({ choices: [{ message: { content: JSON.stringify({ shop: null, domain: null, title: null, ...read }) } }] }, { status: status.gateway })
    : Response.json({ success: true, data: { web: results } }, { status: status.firecrawl }));
  vi.stubGlobal("fetch", fetch);
  return fetch;
}
const searches = (fetch: ReturnType<typeof stub>) =>
  fetch.mock.calls.filter(([url]) => url === "https://api.firecrawl.dev/v2/search").map(([, init]) => JSON.parse(init?.body as string));
const query = (fetch: ReturnType<typeof stub>) => searches(fetch).map((body) => body.query);

beforeEach(() => { vi.stubEnv("AI_GATEWAY_API_KEY", "gateway-key"); vi.stubEnv("FIRECRAWL_API_KEY", "firecrawl-key"); });
afterEach(() => { vi.unstubAllEnvs(); vi.unstubAllGlobals(); });

describe("searching for a Screenshot's listing", () => {
  test("without a signed-in User is rejected before anything is called", async () => {
    const fetch = stub({ title: "Coat" });
    await expect(convexTest(schema, modules).action(api.matches.search, { image })).rejects.toThrow(/Not signed in/);
    expect(fetch).not.toHaveBeenCalled();
  });

  test("reads the Screenshot with the server's key, then searches its title on the shop's site", async () => {
    const fetch = stub({ shop: "SSENSE", domain: "ssense.com", title: "Lemaire Check Shirt" }, [
      { url: "https://www.ssense.com/en-us/men/product/lemaire/check-shirt/123", title: "Lemaire Check Shirt" },
    ]);
    const candidates = await convexTest(schema, modules).withIdentity(alice).action(api.matches.search, { image });
    expect(candidates).toEqual([{ url: "https://www.ssense.com/en-us/men/product/lemaire/check-shirt/123", title: "Lemaire Check Shirt", domain: "ssense.com" }]);
    const [gateway, firecrawl] = fetch.mock.calls;
    expect(gateway[0]).toBe("https://ai-gateway.vercel.sh/v1/chat/completions");
    expect(gateway[1]!.headers).toMatchObject({ Authorization: "Bearer gateway-key" });
    expect(gateway[1]!.body).toContain(`data:image/jpeg;base64,${image}`);
    expect(firecrawl[1]!.headers).toMatchObject({ Authorization: "Bearer firecrawl-key" });
    expect(query(fetch)).toEqual(["Lemaire Check Shirt site:ssense.com"]);
  });

  test("searches the whole web when the shop's domain is unknown", async () => {
    const fetch = stub({ shop: "Some app", domain: null, title: "Red coat" });
    await convexTest(schema, modules).withIdentity(alice).action(api.matches.search, { image });
    expect(query(fetch)).toEqual(["Red coat"]);
  });

  test("a Screenshot with no product title finds nothing, without searching", async () => {
    const fetch = stub({ shop: "Vinted", domain: "vinted.co.uk", title: null });
    expect(await convexTest(schema, modules).withIdentity(alice).action(api.matches.search, { image })).toEqual([]);
    expect(query(fetch)).toEqual([]);
  });

  test("drops non-shop pages but keeps resellers, at most five", async () => {
    const page = (host: string) => ({ url: `https://${host}/item` });
    stub({ title: "Coat" }, [
      page("www.pinterest.co.uk"), page("old.reddit.com"), page("www.google.com"), page("www.instagram.com"),
      page("www.tiktok.com"), page("x.com"), page("twitter.com"), page("m.facebook.com"), page("blog.tumblr.com"), page("en.wikipedia.org"),
      page("www.depop.com"), page("www.vinted.co.uk"),
      page("a.example"), page("b.example"), page("c.example"), page("d.example"),
    ]);
    const candidates = await convexTest(schema, modules).withIdentity(alice).action(api.matches.search, { image });
    expect(candidates.map((c) => c.domain)).toEqual(["depop.com", "vinted.co.uk", "a.example", "b.example", "c.example"]);
  });

  test("searches from the User's region when given", async () => {
    const fetch = stub({ domain: "ssense.com", title: "Lemaire Check Shirt" });
    const t = convexTest(schema, modules).withIdentity(alice);
    await t.action(api.matches.search, { image, region: "GB" });
    await t.action(api.matches.search, { image });
    expect(searches(fetch).map((body) => body.country)).toEqual(["GB", undefined]);
    await expect(t.action(api.matches.search, { image, region: "gb" })).rejects.toThrow(/two-letter/);
  });

  test("a failed read or search is reported as a failed search", async () => {
    stub({ title: "Coat" }, [], { gateway: 500, firecrawl: 200 });
    await expect(convexTest(schema, modules).withIdentity(alice).action(api.matches.search, { image })).rejects.toThrow(/Couldn't search/);
    stub({ title: "Coat" }, [], { gateway: 200, firecrawl: 500 });
    await expect(convexTest(schema, modules).withIdentity(alice).action(api.matches.search, { image })).rejects.toThrow(/Couldn't search/);
  });

  test("each User has a daily limit, and other Users are unaffected", async () => {
    const fetch = stub({ title: null });
    const t = convexTest(schema, modules);
    for (let i = 0; i < 30; i++) await t.withIdentity(alice).action(api.matches.search, { image });
    await expect(t.withIdentity(alice).action(api.matches.search, { image })).rejects.toThrow(/limit/);
    expect(fetch).toHaveBeenCalledTimes(30);
    await t.withIdentity({ tokenIdentifier: "test|bob" }).action(api.matches.search, { image });
  });
});

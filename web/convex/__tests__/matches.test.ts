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
    const candidate = await convexTest(schema, modules).withIdentity(alice).action(api.matches.search, { image });
    expect(candidate).toEqual({ url: "https://www.ssense.com/en-us/men/product/lemaire/check-shirt/123", title: "Lemaire Check Shirt", domain: "ssense.com" });
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
    expect(await convexTest(schema, modules).withIdentity(alice).action(api.matches.search, { image })).toBeNull();
    expect(query(fetch)).toEqual([]);
  });

  test("a non-shop top result finds nothing, but resellers are kept", async () => {
    const t = convexTest(schema, modules).withIdentity(alice);
    for (const host of ["www.pinterest.co.uk", "old.reddit.com", "www.google.com", "www.instagram.com", "www.tiktok.com",
      "x.com", "twitter.com", "m.facebook.com", "blog.tumblr.com", "en.wikipedia.org"]) {
      stub({ title: "Coat" }, [{ url: `https://${host}/item` }]);
      expect(await t.action(api.matches.search, { image })).toBeNull();
    }
    for (const host of ["www.depop.com", "www.vinted.co.uk"]) {
      stub({ title: "Coat" }, [{ url: `https://${host}/item` }]);
      expect((await t.action(api.matches.search, { image }))?.domain).toBe(host.replace("www.", ""));
    }
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
});

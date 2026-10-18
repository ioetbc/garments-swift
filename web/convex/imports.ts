"use node";

import { ConvexError, v } from "convex/values";
import { action, type ActionCtx } from "./_generated/server";
import { createDiagnosticsHandler } from "../lib/import-diagnostics";
import { createImportHandler } from "../lib/import-product";
import { createScrapeHandler } from "../lib/scrape";

const importHandler = createImportHandler();
// The disk cache needs a persistent filesystem, which Convex actions don't have.
const scrapeHandler = createScrapeHandler(undefined, undefined, null);
const logHandler = createDiagnosticsHandler();
const nullable = <T extends Parameters<typeof v.union>[0]>(value: T) => v.union(value, v.null());

// ponytail: the Next route handlers run as-is behind a synthetic Request, so their validation and tests carry over.
async function call(ctx: ActionCtx, handler: (request: Request) => Promise<Response>, body: string, type = "application/json") {
  if (!(await ctx.auth.getUserIdentity())) throw new ConvexError("Not signed in.");
  const response = await handler(new Request("https://garms.invalid", { method: "POST", headers: { "Content-Type": type }, body }));
  const result = await response.json();
  if (!response.ok) throw new ConvexError([result.error ?? `HTTP ${response.status}`, ...(result.diagnostics ?? [])].join("\n"));
  return result;
}

/** A product page's title, Price and images, through Firecrawl. */
export const product = action({
  args: { url: v.string() },
  returns: v.object({
    url: v.string(), title: nullable(v.string()), imageURL: nullable(v.string()), imageURLs: v.array(v.string()),
    price: nullable(v.object({ amount: v.number(), currency: v.string() })), diagnostics: v.array(v.string()),
  }),
  handler: (ctx, args) => call(ctx, importHandler, JSON.stringify(args)),
});

/** A page's Markdown and its availability classification. */
export const scrape = action({
  args: { url: v.string() },
  returns: v.object({
    url: v.string(), markdown: v.string(), title: nullable(v.string()), statusCode: nullable(v.number()),
    classification: v.object({ status: v.string(), error: nullable(v.string()), model: v.string() }), updatedAt: v.string(),
  }),
  handler: (ctx, args) => call(ctx, scrapeHandler, JSON.stringify(args)),
});

/** Writes a phone's import processing log to the deployment's logs. */
export const log = action({
  args: { report: v.string() },
  returns: v.null(),
  handler: async (ctx, args) => { await call(ctx, logHandler, args.report, "text/plain; charset=utf-8"); return null; },
});

"use node";

import { v } from "convex/values";
import { Effect, Layer } from "effect";
import { action } from "./_generated/server";
import { Auth } from "./lib/auth";
import { run } from "./lib/edge";
import { ProductPageReader } from "./lib/product-page.client";
import { importedProduct } from "./validators";

/** A product page's title, Price and images, through Firecrawl. Signed-in Users only. */
export const product = action({
  args: { url: v.string() },
  returns: importedProduct,
  handler: (ctx, args) => run(Layer.merge(Auth.layer(ctx), ProductPageReader.layer), Effect.gen(function* () {
    yield* (yield* Auth).identity;
    return yield* (yield* ProductPageReader).read(args.url);
  })),
});

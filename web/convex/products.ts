import { v } from "convex/values";
import { Effect } from "effect";
import { mutation } from "./_generated/server";
import { runMutation } from "./lib/edge";
import { ProductService } from "./lib/product.service";

/** Deletes a Product, every Sticker of it on any of the owner's Canvases, and its stored files. */
export const remove = mutation({
  args: { product: v.string() },
  returns: v.null(),
  handler: (ctx, args) => runMutation(ctx, ProductService.use((products) =>
    products.remove(args.product).pipe(Effect.as(null)))),
});

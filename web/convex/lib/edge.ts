import { ConvexError } from "convex/values";
import { Effect, Layer } from "effect";
import type { ActionCtx, MutationCtx, QueryCtx } from "../_generated/server";
import { AccountService, DeletionBatches } from "./account.service";
import { Auth } from "./auth";
import { CanvasService } from "./canvas.service";
import { ClerkClient } from "./clerk.client";
import { Db } from "./db";
import { messageOf, type GarmsError } from "./errors";
import { FileService } from "./file.service";
import { ListingSearch } from "./listing.client";
import { MatchService, SearchQuota } from "./match.service";
import { ProductService } from "./product.service";
import { ScreenshotReader } from "./screenshot.client";
import { UserService } from "./user.service";

/** What a query's or mutation's program may use. */
type Services = UserService | CanvasService | ProductService | FileService | Db;

// Services on top of UserService; each handler provides Db and Auth.
const services = Layer.mergeAll(CanvasService.layer, ProductService.layer, FileService.layer).pipe(
  Layer.provideMerge(UserService.layer),
);

/**
 * Runs a handler's program once, as the edge: Effect stays inside, callers see plain values or a ConvexError.
 * For handlers that need their own layer, such as actions on the Node runtime.
 */
export const run = <A, R>(layer: Layer.Layer<R>, effect: Effect.Effect<A, GarmsError, R>): Promise<A> =>
  effect.pipe(
    Effect.provide(layer),
    Effect.catch((error) => Effect.die(new ConvexError(messageOf(error)))),
    Effect.runPromise,
  );

/** Runs a query's program once. A write in a query is a defect. */
export const runQuery = <A>(ctx: QueryCtx, effect: Effect.Effect<A, GarmsError, Services>) =>
  run(services.pipe(Layer.provideMerge(Layer.merge(Db.query(ctx), Auth.layer(ctx)))), effect);

/** Runs a mutation's program once. */
export const runMutation = <A>(ctx: MutationCtx, effect: Effect.Effect<A, GarmsError, Services>) =>
  run(services.pipe(Layer.provideMerge(Layer.merge(Db.mutation(ctx), Auth.layer(ctx)))), effect);

/** Runs an action's program once. Actions have no database; they reach it through mutations. */
export const runAction = <A>(ctx: ActionCtx, effect: Effect.Effect<A, GarmsError, AccountService | MatchService>) =>
  run(Layer.merge(AccountService.layer, MatchService.layer).pipe(Layer.provide(Layer.mergeAll(
    Auth.layer(ctx), DeletionBatches.layer(ctx), ClerkClient.layer, SearchQuota.layer(ctx), ScreenshotReader.layer, ListingSearch.layer,
  ))), effect);

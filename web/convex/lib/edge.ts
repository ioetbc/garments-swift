import { ConvexError } from "convex/values";
import { Effect, Layer } from "effect";
import type { ActionCtx, MutationCtx, QueryCtx } from "../_generated/server";
import { AccountService, DeletionBatches } from "./account.service";
import { Auth } from "./auth";
import { CanvasRepository } from "./canvas.repository";
import { CanvasService } from "./canvas.service";
import { ClerkClient } from "./clerk.client";
import { ConvexContext } from "./context";
import { messageOf, type GarmsError } from "./errors";
import { FileRepository } from "./file.repository";
import { FileService } from "./file.service";
import { GroupRepository } from "./group.repository";
import { LinkRepository } from "./link.repository";
import { ProductRepository } from "./product.repository";
import { ProductService } from "./product.service";
import { SeedService } from "./seed.service";
import { StickerRepository } from "./sticker.repository";
import { UserRepository } from "./user.repository";
import { UserService } from "./user.service";

/** The services a handler may call. */
type Services = UserService | CanvasService | ProductService | FileService | SeedService;

// Services on top of repositories; each handler provides ConvexContext and Auth.
const services = Layer.mergeAll(UserService.layer, CanvasService.layer, ProductService.layer, FileService.layer, SeedService.layer).pipe(
  Layer.provide(Layer.mergeAll(
    UserRepository.layer, CanvasRepository.layer, ProductRepository.layer,
    StickerRepository.layer, GroupRepository.layer, LinkRepository.layer, FileRepository.layer,
  )),
);

// Handlers are the edge: Effect stays inside, callers see plain values or a ConvexError.
const run = <A, R>(layer: Layer.Layer<R>, effect: Effect.Effect<A, GarmsError, R>): Promise<A> =>
  effect.pipe(
    Effect.provide(layer),
    Effect.catch((error) => Effect.die(new ConvexError(messageOf(error)))),
    Effect.runPromise,
  );

/** Runs a query's program once. A repository write in a query is a defect. */
export const runQuery = <A>(ctx: QueryCtx, effect: Effect.Effect<A, GarmsError, Services>) =>
  run(services.pipe(Layer.provide(Layer.merge(ConvexContext.query(ctx), Auth.layer(ctx)))), effect);

/** Runs a mutation's program once. */
export const runMutation = <A>(ctx: MutationCtx, effect: Effect.Effect<A, GarmsError, Services>) =>
  run(services.pipe(Layer.provide(Layer.merge(ConvexContext.mutation(ctx), Auth.layer(ctx)))), effect);

/** Runs an action's program once. Actions have no database; they reach it through mutations. */
export const runAction = <A>(ctx: ActionCtx, effect: Effect.Effect<A, GarmsError, AccountService>) =>
  run(AccountService.layer.pipe(Layer.provide(Layer.mergeAll(Auth.layer(ctx), DeletionBatches.layer(ctx), ClerkClient.layer))), effect);

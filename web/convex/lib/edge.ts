import { ConvexError } from "convex/values";
import { Effect, Layer } from "effect";
import type { MutationCtx, QueryCtx } from "../_generated/server";
import { Auth } from "./auth";
import { CanvasRepository } from "./canvas.repository";
import { CanvasService } from "./canvas.service";
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

// Services on top of repositories; only ConvexContext is left for each handler to provide.
const services = Layer.mergeAll(UserService.layer, CanvasService.layer, ProductService.layer, FileService.layer, SeedService.layer).pipe(
  Layer.provide(Layer.mergeAll(
    Auth.layer, UserRepository.layer, CanvasRepository.layer, ProductRepository.layer,
    StickerRepository.layer, GroupRepository.layer, LinkRepository.layer, FileRepository.layer,
  )),
);

// Handlers are the edge: Effect stays inside, callers see plain values or a ConvexError.
const run = <A>(context: Layer.Layer<ConvexContext>, effect: Effect.Effect<A, GarmsError, Services>): Promise<A> =>
  effect.pipe(
    Effect.provide(services.pipe(Layer.provide(context))),
    Effect.catch((error) => Effect.die(new ConvexError(messageOf(error)))),
    Effect.runPromise,
  );

/** Runs a query's program once. A repository write in a query is a defect. */
export const runQuery = <A>(ctx: QueryCtx, effect: Effect.Effect<A, GarmsError, Services>) =>
  run(ConvexContext.query(ctx), effect);

/** Runs a mutation's program once. */
export const runMutation = <A>(ctx: MutationCtx, effect: Effect.Effect<A, GarmsError, Services>) =>
  run(ConvexContext.mutation(ctx), effect);

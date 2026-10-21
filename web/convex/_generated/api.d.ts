/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as canvases from "../canvases.js";
import type * as files from "../files.js";
import type * as imports from "../imports.js";
import type * as lib_auth from "../lib/auth.js";
import type * as lib_db from "../lib/db.js";
import type * as lib_edge from "../lib/edge.js";
import type * as lib_errors from "../lib/errors.js";
import type * as matches from "../matches.js";
import type * as products from "../products.js";
import type * as users from "../users.js";
import type * as validators from "../validators.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  canvases: typeof canvases;
  files: typeof files;
  imports: typeof imports;
  "lib/auth": typeof lib_auth;
  "lib/db": typeof lib_db;
  "lib/edge": typeof lib_edge;
  "lib/errors": typeof lib_errors;
  matches: typeof matches;
  products: typeof products;
  users: typeof users;
  validators: typeof validators;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};

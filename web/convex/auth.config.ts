import type { AuthConfig } from "convex/server";

// Each deployment trusts its own Clerk instance: dev ↔ Clerk development, prod ↔ Clerk production.
export default {
  providers: [{ domain: process.env.CLERK_FRONTEND_API_URL!, applicationID: "convex" }],
} satisfies AuthConfig;

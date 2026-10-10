# Clerk with Sign in with Apple for authentication

Every Convex row is scoped to a User, so sign-in is required before the Canvas appears; there are no anonymous Users. We use Clerk (Sign in with Apple only) rather than wiring Apple directly into Convex as an OIDC provider, because Apple identity tokens expire after ~10 minutes and cannot be refreshed on-device — doing it ourselves means building a server-side token exchange. Clerk handles refresh and cached sessions, has a documented Convex Swift integration, and lets us add other sign-in methods later without touching Convex.

## Considered Options

- **Direct Apple OIDC in Convex** — no third party, but we'd own token refresh.
- **Anonymous-first, upgrade later** — rejected: needs account merging and orphan cleanup for a data model we don't have yet.

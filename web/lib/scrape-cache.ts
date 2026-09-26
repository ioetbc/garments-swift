import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import type { ScrapeResult } from "./scrape";

// Bump when evidence extraction changes so stale classifications are refreshed.
const CACHE_VERSION = 5;

export const CACHE_TTL_MS = 24 * 60 * 60 * 1000;

export function createScrapeCache(
  directory = process.env.SCRAPE_CACHE_DIR ?? path.join(process.cwd(), ".cache", "scrape"),
  now: () => number = Date.now,
) {
  const filename = (url: string) => path.join(directory, `${createHash("sha256").update(url).digest("hex")}.json`);
  return {
    async get(url: string): Promise<ScrapeResult | null> {
      try {
        const entry = JSON.parse(await readFile(filename(url), "utf8"));
        const age = now() - Date.parse(entry.updatedAt);
        if (entry.cacheVersion !== CACHE_VERSION || !Number.isFinite(age) || age < 0 || age >= CACHE_TTL_MS ||
            entry.url !== url || typeof entry.markdown !== "string" || !entry.markdown.trim() ||
            !(entry.title === null || typeof entry.title === "string") ||
            !(entry.statusCode === null || typeof entry.statusCode === "number") ||
            !["available", "sold"].includes(entry.classification?.status) ||
            entry.classification.error !== null || typeof entry.classification.model !== "string") return null;
        const { cacheVersion, ...result } = entry;
        void cacheVersion;
        return result as ScrapeResult;
      } catch (error) {
        if (!(error instanceof SyntaxError) && (error as NodeJS.ErrnoException).code !== "ENOENT") {
          console.warn("Could not read scrape cache.", error);
        }
        return null;
      }
    },
    async set(result: ScrapeResult): Promise<void> {
      if (result.classification.status === "unknown") return;
      const destination = filename(result.url);
      const temporary = `${destination}.${randomUUID()}.tmp`;
      try {
        await mkdir(directory, { recursive: true });
        await writeFile(temporary, JSON.stringify({ ...result, cacheVersion: CACHE_VERSION }, null, 2), { encoding: "utf8", mode: 0o600 });
        await rename(temporary, destination);
      } catch (error) {
        // A disk failure must not discard an otherwise usable paid result.
        console.warn("Could not save scrape cache.", error);
      } finally {
        await rm(temporary, { force: true }).catch(() => {});
      }
    },
  };
}

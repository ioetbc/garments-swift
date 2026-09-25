import { createScrapeHandler } from "@/lib/scrape";

export const runtime = "nodejs";
// Allow for the bounded scrape (50s) followed by classification (20s).
export const maxDuration = 90;
export const POST = createScrapeHandler();

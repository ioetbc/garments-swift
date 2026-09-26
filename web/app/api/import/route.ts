import { createImportHandler } from "@/lib/import-product";
export const runtime = "nodejs";
export const maxDuration = 60;
export const POST = createImportHandler();

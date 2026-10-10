// Seeds a developer account's Canvas with the sample Products on the configured Convex deployment.
// Run from web/: bun seed/seed-canvas.ts <tokenIdentifier> [count]
// Sign in on the app first; the tokenIdentifier is on your row in the `users` table.
import { readFile } from "node:fs/promises";
import path from "node:path";
import samples from "./samples.json";

const [tokenIdentifier, count = "100"] = process.argv.slice(2);
if (!tokenIdentifier) throw new Error("Usage: bun seed/seed-canvas.ts <tokenIdentifier> [count]");

function convexRun(name: string, args: unknown): unknown {
  const result = Bun.spawnSync(["npx", "convex", "run", name, JSON.stringify(args)], { stderr: "inherit" });
  if (!result.success) throw new Error(`convex run ${name} failed`);
  const output = result.stdout.toString().trim();
  return output ? JSON.parse(output) : null;
}

const uploaded = [];
for (const { file, ...sample } of samples) {
  const url = convexRun("seed:uploadUrl", {}) as string;
  const response = await fetch(url, {
    method: "POST", headers: { "Content-Type": "image/png" },
    body: await readFile(path.join(import.meta.dir, file)),
  });
  if (!response.ok) throw new Error(`Upload of ${file} failed: HTTP ${response.status}`);
  const { storageId } = (await response.json()) as { storageId: string };
  uploaded.push({ ...sample, storageId });
  console.log(`Uploaded ${file}`);
}
convexRun("seed:run", { tokenIdentifier, samples: uploaded, count: Number(count) });
console.log(`Seeded ${count} Stickers for ${tokenIdentifier}.`);

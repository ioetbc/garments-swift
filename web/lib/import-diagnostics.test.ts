import { test } from "node:test";
import { strict as assert } from "node:assert";
import { createDiagnosticsHandler } from "./import-diagnostics";

const request = (body: string, type = "text/plain; charset=utf-8") => new Request("https://garms.test/api/import/diagnostics", {
  method: "POST", headers: { "Content-Type": type }, body,
});
test("prints a readable report and strips terminal controls", async () => {
  const reports: string[] = [];
  const handler = createDiagnosticsHandler(report => reports.push(report));
  const response = await handler(request("Import: 123\nVision failed [domain, code 7]\n" + String.fromCharCode(27) + "[31m"));
  assert.equal(response.status, 200);
  assert.equal(reports.length, 1);
  assert.ok(reports[0].includes("Vision failed [domain, code 7]\n"));
  assert.ok(!reports[0].includes(String.fromCharCode(27)));
  assert.equal(response.headers.get("cache-control"), "no-store");
});
test("rejects invalid and oversized reports without printing", async () => {
  let writes = 0;
  const handler = createDiagnosticsHandler(() => { writes++; });
  assert.equal((await handler(request(" "))).status, 400);
  assert.equal((await handler(request("{}", "application/json"))).status, 415);
  assert.equal((await handler(request("a".repeat(256 * 1024 + 1)))).status, 413);
  assert.equal(writes, 0);
});
test("does not report success when terminal output fails", async () => {
  const handler = createDiagnosticsHandler(() => { throw new Error("write failed"); });
  assert.equal((await handler(request("Import report"))).status, 500);
});

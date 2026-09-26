const MAX_REPORT_BYTES = 256 * 1024;
const json = (body: unknown, status = 200) => Response.json(body, { status, headers: { "Cache-Control": "no-store" } });

export function createDiagnosticsHandler(write: (report: string) => void = report => console.info(report)) {
  return async (request: Request) => {
    if (request.headers.get("content-type")?.split(";")[0].trim() !== "text/plain") {
      return json({ error: "Content-Type must be text/plain." }, 415);
    }
    let report: string;
    try {
      const reader = request.body?.getReader();
      if (!reader) return json({ error: "Provide a processing log." }, 400);
      const chunks: Uint8Array[] = [];
      let size = 0;
      while (true) {
        const { done, value } = await reader.read();
        if (done) break;
        size += value.byteLength;
        if (size > MAX_REPORT_BYTES) {
          await reader.cancel();
          return json({ error: "Processing log exceeds 256 KB." }, 413);
        }
        chunks.push(value);
      }
      report = new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks));
      if (!report.trim()) return json({ error: "Provide a processing log." }, 400);
    } catch { return json({ error: "Could not read the processing log." }, 400); }
    // Preserve readable reports while removing terminal control characters.
    const printable = Array.from(report).filter(character => {
      const code = character.codePointAt(0)!;
      return code === 10 || code === 9 || code >= 32 && !(code >= 127 && code <= 159);
    }).join("");
    try {
      write(`\n----- GARMS IMPORT LOG FROM PHONE -----\n${printable}\n----- END GARMS IMPORT LOG -----\n`);
      return json({ message: "Log sent to the API server terminal." });
    } catch { return json({ error: "Could not write the log to the server terminal." }, 500); }
  };
}

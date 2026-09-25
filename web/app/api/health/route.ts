export function GET() {
  return Response.json(
    { status: "ok", message: "Connected to Garms." },
    { headers: { "Cache-Control": "no-store" } },
  );
}

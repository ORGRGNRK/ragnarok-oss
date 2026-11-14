// proved.rgnrk.co: serves ONE page, the agent run the owner chose to show. Nothing here connects back to Alexus.
// GET /            the published page (404 until one is published)
// PUT /publish     replace the page   (Bearer PUBLISH_TOKEN; body is the whole HTML page)
// DELETE /publish  take the page down (Bearer PUBLISH_TOKEN)
const MAX = 1_000_000;

function same(a, b) {            // constant-time compare
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let d = x.length ^ y.length;
  for (let i = 0; i < x.length; i++) d |= x[i] ^ y[i % (y.length || 1)];
  return d === 0;
}

const HEADERS = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "no-cache",
  // the page is static text and inline styles only: no scripts, no images, no requests, no framing
  "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
};

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (url.pathname === "/publish" && (req.method === "PUT" || req.method === "DELETE")) {
      const got = req.headers.get("authorization") || "";
      if (!env.PUBLISH_TOKEN || !same(got, "Bearer " + env.PUBLISH_TOKEN)) return new Response("unauthorized\n", { status: 401 });
      if (req.method === "DELETE") { await env.PAGES.delete("page"); return Response.json({ ok: true, published: false }); }
      const body = await req.text();
      if (body.length > MAX || !body.startsWith("<!doctype html>") || /<script/i.test(body)) return new Response("not a page this site will serve\n", { status: 400 });
      await env.PAGES.put("page", body);
      return Response.json({ ok: true, published: true, bytes: body.length });
    }
    if (url.pathname === "/" && (req.method === "GET" || req.method === "HEAD")) {
      const page = await env.PAGES.get("page");
      if (!page) return new Response("Nothing is published here right now.\n", { status: 404, headers: { "content-type": "text/plain; charset=utf-8" } });
      return new Response(req.method === "HEAD" ? null : page, { headers: HEADERS });
    }
    return new Response("not found\n", { status: 404 });
  },
};

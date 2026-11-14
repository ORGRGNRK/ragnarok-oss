// emblem.rgnrk.co: one public page, the Ragnarok opening scene with the petals spinning forever.
// Static: the page is index.html in this folder, bundled at deploy. Nothing here connects back to any machine.
import page from "./index.html";

const HEADERS = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "public, max-age=300",
  // inline script + style only: no external requests, no framing
  "content-security-policy": "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  "x-content-type-options": "nosniff",
  "referrer-policy": "no-referrer",
};

export default {
  async fetch(request) {
    const { pathname } = new URL(request.url);
    if (request.method !== "GET" && request.method !== "HEAD") return new Response("Method not allowed", { status: 405 });
    if (pathname !== "/") return Response.redirect(new URL("/", request.url).toString(), 302);
    return new Response(request.method === "HEAD" ? null : page, { headers: HEADERS });
  },
};

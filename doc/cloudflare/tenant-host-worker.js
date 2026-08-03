/**
 * Cloudflare Worker: tenant website host rewriting.
 *
 * WHY THIS EXISTS
 *
 * Cloudflare for SaaS forwards the visitor's original Host header to the origin. Render
 * rejects any Host it does not recognise as a registered domain for the service:
 *
 *     Host: renterinsight-api-prod.onrender.com  ->  200
 *     Host: www.somedealer.com                   ->  403
 *
 * So every dealer domain would 403 at the origin. Registering each dealer domain with
 * Render instead would work, but costs $0.25/domain above the plan's included 15 and
 * duplicates the custom-hostname management Cloudflare is already doing.
 *
 * This Worker rewrites Host to the Render service hostname so the request is accepted, and
 * passes the real hostname along in X-Tenant-Host. Rails reads that instead of request.host
 * (see Websites::RequestHost).
 *
 * The secret matters: without it, anyone could call the Render hostname directly with an
 * X-Tenant-Host of their choosing and be served that dealer's site under it. Rails only
 * trusts the header when the secret matches.
 *
 * DEPLOY
 *
 *   1. Workers & Pages > Create > Worker. Paste this in.
 *   2. Settings > Variables, add (encrypt both):
 *        ORIGIN_HOST    = renterinsight-api-prod.onrender.com
 *        PROXY_SECRET   = <generate: openssl rand -hex 32>
 *   3. Set the same value as TENANT_PROXY_SECRET in Render.
 *   4. Workers Routes: add  *\/*  on the zone, or a route per custom hostname.
 *
 * Until TENANT_PROXY_SECRET is set in Render, Rails ignores the header and falls back to
 * request.host, so deploying this half-configured changes nothing rather than breaking
 * anything.
 */

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const visitorHost = url.hostname;

    // Changing the URL's hostname is what changes the outbound Host header. Setting a Host
    // header directly is ignored by the Workers runtime.
    url.hostname = env.ORIGIN_HOST;

    const headers = new Headers(request.headers);
    headers.set('X-Tenant-Host', visitorHost);
    headers.set('X-Tenant-Proxy-Secret', env.PROXY_SECRET);
    // The origin terminates TLS with Cloudflare, not the visitor, so tell it what the
    // visitor actually used or every generated URL comes back as http.
    headers.set('X-Forwarded-Proto', 'https');

    const response = await fetch(new URL(url).toString(), {
      method: request.method,
      headers,
      body: request.method === 'GET' || request.method === 'HEAD' ? undefined : request.body,
      // Redirects belong to the visitor. Following them here would resolve a dealer's
      // canonical-host redirect against the origin hostname instead of theirs.
      redirect: 'manual',
    });

    // Rewrite any Location pointing at the origin back to the visitor's own hostname, so a
    // redirect never leaks the Render hostname into a dealer's address bar.
    const location = response.headers.get('Location');
    if (location && location.includes(env.ORIGIN_HOST)) {
      const fixed = new Headers(response.headers);
      fixed.set('Location', location.replaceAll(env.ORIGIN_HOST, visitorHost));
      return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers: fixed,
      });
    }

    return response;
  },
};

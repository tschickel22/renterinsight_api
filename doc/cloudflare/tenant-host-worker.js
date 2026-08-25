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
 *        ORIGIN_HOST    = the Render service for THIS zone's environment
 *                         staging: renterinsight-api-staging.onrender.com
 *                         prod:    renterinsight-api-prod.onrender.com
 *        PROXY_SECRET   = openssl rand -hex 32   (run it; paste the output)
 *   3. Set that same value as TENANT_PROXY_SECRET on the matching Render service.
 *   4. Workers Routes: add  *\/*  on the zone, or a route per custom hostname.
 *
 * ORIGIN_HOST must match the zone's fallback origin. They are the same server described
 * twice, and pointing them at different environments sends traffic somewhere the code is
 * not deployed while every setting still looks correct.
 *
 * ONE ZONE PER ENVIRONMENT
 *
 * A Cloudflare zone has exactly one fallback origin, so a single zone cannot serve staging
 * and production at once. Two Workers do not help: they would share that fallback origin,
 * and dealer hostnames are arbitrary custom hostnames rather than subdomains a route could
 * separate by environment. Use a separate cheap domain as a second zone instead.
 *
 * Until TENANT_PROXY_SECRET is set in Render, Rails ignores the header and falls back to
 * request.host, so deploying this half-configured changes nothing rather than breaking
 * anything.
 */

/**
 * CACHING
 *
 * Cache Rules on the zone cannot do this. The route is star-slash-star, so this Worker owns
 * every request, and the origin it fetches is a Render hostname outside the zone. Cloudflare's
 * cache never sees it, which is why dealer pages answered cf-cache-status: DYNAMIC and every
 * single page view reached Rails.
 *
 * The cache key is the VISITOR's URL and never the outbound one. The Host rewrite below points
 * every dealer at the same Render hostname, so keying on the outbound URL would make
 * tomshotsauce.com/about and any other dealer's /about the same entry, and one dealer would be
 * served another's site under their own domain. That is the trap in switching on cacheEverything
 * here, and it is the reason this is hand-rolled rather than delegated to a Cache Rule.
 *
 * Freshness is tracked here rather than left to the Cache API, because the Cache API honours
 * max-age but not stale-if-error: it drops an entry the moment it expires, which is precisely
 * when an outage needs it. Entries are stored with a long TTL and their real age checked on
 * read, so an expired copy is still on hand when the origin is unreachable.
 *
 * Dealer sites are served by the same Rails process as the API, so an API deploy or restart is
 * also a dealer site restart. That is what STALE_IF_ERROR_SECONDS covers.
 */

// Matches s-maxage in Public::SitesController. Kept in step by hand: they describe the same
// intent from two sides, and the controller's value is the one that documents why.
const FRESH_SECONDS = 300;
// How long an expired copy is kept for use during an outage. Matches stale-if-error there.
const STALE_IF_ERROR_SECONDS = 86400;
// Our own timestamp rather than the Age header, so freshness does not depend on how a
// particular edge location accounts for time.
const CACHED_AT = 'x-dt-cached-at';
// The origin's real Cache-Control, parked while the stored copy carries the long retention
// TTL instead. See served().
const ORIGIN_CC = 'x-dt-origin-cache-control';

// Headers worth keeping on a snapshot. Deliberately a short allow-list rather than the whole
// set: KV metadata is capped at 1024 bytes, and most of what an origin sends (request ids,
// timing, nel reports) describes one particular response rather than the page.
const SNAPSHOT_HEADERS = ['content-type', 'content-language', 'cache-control', 'link'];

function ageOf(response) {
  const stamp = Number(response.headers.get(CACHED_AT));
  if (!stamp) return Infinity;
  return (Date.now() - stamp) / 1000;
}

/**
 * Last known good copy of a page, kept at the edge with no expiry.
 *
 * The edge cache cannot cover an outage on its own. Entries expire, they are per colo, and a
 * URL nobody has requested recently is not in the cache at all, so the first visitor to a
 * quiet page during a restart still meets a dead origin. Once a page has been served
 * successfully even once, this keeps it reachable.
 *
 * Written only on a cache miss, which the 24h edge entry already throttles. At a few dealers
 * that is a handful of writes a day. At a few hundred it would want a content hash to skip
 * rewriting unchanged pages, since KV's free tier allows 1000 writes a day and a miss happens
 * once per colo.
 */
function snapshotWrite(env, ctx, key, response, body) {
  if (!env.TENANT_SNAPSHOTS) return;

  const metadata = { stored_at: Date.now() };
  for (const name of SNAPSHOT_HEADERS) {
    const value = response.headers.get(name);
    if (value) metadata[name] = value;
  }

  // Never blocks the response, and never fails one. A snapshot is a safety net; a broken net
  // must not take down the thing it was meant to catch.
  ctx.waitUntil(env.TENANT_SNAPSHOTS.put(key, body, { metadata }).catch(() => {}));
}

async function snapshotRead(env, key) {
  if (!env.TENANT_SNAPSHOTS) return null;

  try {
    const { value, metadata } = await env.TENANT_SNAPSHOTS.getWithMetadata(key, { type: 'arrayBuffer' });
    if (!value) return null;

    const headers = new Headers();
    for (const name of SNAPSHOT_HEADERS) {
      if (metadata && metadata[name]) headers.set(name, metadata[name]);
    }
    // The origin's own Cache-Control rides along in metadata, so a visitor served a snapshot
    // still revalidates on the normal schedule and picks up the real page as soon as the
    // origin is back.
    return new Response(value, { status: 200, headers });
  } catch (err) {
    return null;
  }
}

// Marks where the response came from, so a HIT can be told from a STALE without reading logs.
//
// Also puts the origin's Cache-Control back. Stored copies deliberately carry a ~24h TTL so
// they survive past their freshness window and are still on hand during an outage, but that
// value must never reach a visitor: their browser would hold the page for a day, and a page
// held that long points at a bundle that no longer exists after the next frontend deploy.
// That is the blank-dealer-site failure this whole design exists to avoid, reintroduced one
// layer further out.
function served(response, status) {
  const headers = new Headers(response.headers);
  headers.set('X-DT-Cache', status);

  const originCacheControl = headers.get(ORIGIN_CC);
  if (originCacheControl) headers.set('Cache-Control', originCacheControl);
  headers.delete(ORIGIN_CC);
  headers.delete(CACHED_AT);

  return new Response(response.body, { status: response.status, statusText: response.statusText, headers });
}

export default {
  async fetch(request, env, ctx) {
    const visitorUrl = new URL(request.url);
    const visitorHost = visitorUrl.hostname;

    // GET only. A form post must never be answered from cache, and HEAD is rare enough here
    // that special-casing it earns nothing.
    const cacheable = request.method === 'GET';
    const cache = caches.default;
    // Built from the URL alone. Passing the original request would fold its headers into the
    // key and fragment the cache per visitor.
    const cacheKey = cacheable ? new Request(visitorUrl.toString(), { method: 'GET' }) : null;

    let cached = null;
    if (cacheable) {
      try {
        cached = (await cache.match(cacheKey)) || null;
      } catch (err) {
        // A cache failure must never take a dealer site down. Fall through and proxy.
        cached = null;
      }
      if (cached && ageOf(cached) < FRESH_SECONDS) return served(cached, 'HIT');
    }

    // Changing the URL's hostname is what changes the outbound Host header. Setting a Host
    // header directly is ignored by the Workers runtime.
    const url = new URL(request.url);
    url.hostname = env.ORIGIN_HOST;

    const headers = new Headers(request.headers);
    headers.set('X-Tenant-Host', visitorHost);
    headers.set('X-Tenant-Proxy-Secret', env.PROXY_SECRET);
    // The origin terminates TLS with Cloudflare, not the visitor, so tell it what the
    // visitor actually used or every generated URL comes back as http.
    headers.set('X-Forwarded-Proto', 'https');

    // The visitor's state, for landing page analytics.
    //
    // CF-IPCountry rides along on its own: Cloudflare attaches it before this Worker runs
    // and the Headers copy above preserves it. Region does not — it exists only on
    // request.cf, which is a Worker-runtime object and never a header, so without this the
    // origin cannot see it at all. Free on every plan; the paid alternative is a managed
    // transform this zone does not have.
    //
    // regionCode, not region: two letters that mean one place, against a display name that
    // arrives spelled differently often enough to split one state into several rows.
    //
    // City is deliberately not forwarded. Most of this traffic is mobile, where the IP
    // resolves to the carrier's regional hub rather than the visitor, so a city column
    // would be confidently wrong. State is the grain an ad decision is actually made at,
    // and far less identifying for a visit that later becomes a named lead.
    const geo = request.cf || {};
    if (geo.regionCode) headers.set('X-DT-Region', String(geo.regionCode).slice(0, 8));

    let response;
    try {
      response = await fetch(new URL(url).toString(), {
        method: request.method,
        headers,
        body: request.method === 'GET' || request.method === 'HEAD' ? undefined : request.body,
        // Redirects belong to the visitor. Following them here would resolve a dealer's
        // canonical-host redirect against the origin hostname instead of theirs.
        redirect: 'manual',
      });
    } catch (err) {
      // Origin unreachable: mid-restart, mid-deploy, or down. An expired copy of a page that
      // has not changed in days beats an error page, for the visitor and for a crawler
      // deciding whether the site is healthy.
      if (cached) return served(cached, 'STALE-ORIGIN-UNREACHABLE');

      // Nothing in this colo's cache. The snapshot is what makes a quiet page survive an
      // outage rather than only the pages that happened to be busy beforehand.
      const snapshot = cacheable ? await snapshotRead(env, visitorUrl.toString()) : null;
      if (snapshot) return served(snapshot, 'SNAPSHOT-ORIGIN-UNREACHABLE');

      throw err;
    }

    if (response.status >= 500) {
      if (cached) return served(cached, 'STALE-ORIGIN-ERROR');

      const snapshot = cacheable ? await snapshotRead(env, visitorUrl.toString()) : null;
      if (snapshot) return served(snapshot, 'SNAPSHOT-ORIGIN-ERROR');
    }

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

    // Only plain successful pages are stored. A Set-Cookie means the response was meant for
    // one visitor, and storing it would hand their session to the next person. Rails already
    // strips the session cookie from these responses; this is the second lock on that door.
    const storable =
      cacheable && response.status === 200 && !response.headers.get('Set-Cookie');

    if (storable) {
      const toStore = new Headers(response.headers);
      toStore.set(CACHED_AT, String(Date.now()));
      // Parked so served() can put it back. Without this the long retention TTL below is what
      // the visitor's browser sees on every HIT.
      const originCacheControl = response.headers.get('Cache-Control');
      if (originCacheControl) toStore.set(ORIGIN_CC, originCacheControl);
      // Overrides the origin's s-maxage so the entry survives past its freshness window and
      // is still there for the outage case above. Freshness is enforced by ageOf, not by this.
      toStore.set('Cache-Control', `public, max-age=${FRESH_SECONDS + STALE_IF_ERROR_SECONDS}`);

      const body = await response.arrayBuffer();
      ctx.waitUntil(cache.put(cacheKey, new Response(body, {
        status: response.status,
        statusText: response.statusText,
        headers: toStore,
      })));

      // Refresh the last known good copy on the way past. Writing here rather than on a hit
      // means the snapshot is only rewritten when a colo actually went to the origin, which
      // is what keeps the write volume down.
      snapshotWrite(env, ctx, visitorUrl.toString(), response, body);

      // Rebuilt from the buffer because the body was consumed reading it. The visitor gets the
      // origin's own Cache-Control, not the long one written above, so their browser still
      // revalidates on the intended schedule.
      return served(new Response(body, {
        status: response.status,
        statusText: response.statusText,
        headers: response.headers,
      }), 'MISS');
    }

    return response;
  },
};

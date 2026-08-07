/**
 * tenant-host-worker
 *
 * Serves dealer sites and tenant subdomains. Render rejects any Host it does
 * not recognise as a registered domain, so the hostname the visitor typed
 * cannot travel in Host and rides in a header instead. Rails reads it back in
 * Websites::RequestHost, which trusts the header only when PROXY_SECRET
 * matches, because otherwise anyone hitting the Render hostname directly could
 * claim to be any dealer's domain and be served that dealer's site.
 *
 * DEPLOYED TWICE from this one file, differing only in bindings:
 *
 *   tenant-host-proxy          ORIGIN_HOST = renterinsight-api-prod.onrender.com
 *   tenant-host-proxy-staging  ORIGIN_HOST = renterinsight-api-staging.onrender.com
 *
 * Two scripts rather than one with a branch, because routes bind per hostname
 * and that is what keeps a staging publish from answering on a production
 * dealer's address. See Websites::SiteAddress for the other half.
 *
 * Which script a given environment binds is set by CLOUDFLARE_WORKER_SCRIPT and
 * read in CloudflareSaasService#create_worker_route.
 *
 * Bindings:
 *   ORIGIN_HOST       plain text, the Render service to forward to
 *   PROXY_SECRET      secret, must equal TENANT_PROXY_SECRET on that Rails service
 *   TENANT_SNAPSHOTS  KV, optional. Last-known-good copies for when the origin
 *                     is down. Every use is guarded, so a deployment without it
 *                     simply loses the offline fallback. Staging has none.
 */

// Serve from cache without asking the origin for this long, then revalidate.
const FRESH_SECONDS = 300
// How long a cached copy may still be served once the origin is failing. A
// dealer's site staying up on slightly stale content beats an error page.
const STALE_IF_ERROR_SECONDS = 86400

const CACHED_AT = 'x-dt-cached-at'
const ORIGIN_CC = 'x-dt-origin-cache-control'
const SNAPSHOT_HEADERS = ['content-type', 'content-language', 'cache-control', 'link']

function ageOf(response) {
  const stamp = Number(response.headers.get(CACHED_AT))
  if (!stamp) return Infinity
  return (Date.now() - stamp) / 1000
}

function snapshotWrite(env, ctx, key, response, body) {
  if (!env.TENANT_SNAPSHOTS) return
  const metadata = { stored_at: Date.now() }
  for (const name of SNAPSHOT_HEADERS) {
    const value = response.headers.get(name)
    if (value) metadata[name] = value
  }
  ctx.waitUntil(env.TENANT_SNAPSHOTS.put(key, body, { metadata }).catch(() => {}))
}

async function snapshotRead(env, key) {
  if (!env.TENANT_SNAPSHOTS) return null
  try {
    const { value, metadata } = await env.TENANT_SNAPSHOTS.getWithMetadata(key, { type: 'arrayBuffer' })
    if (!value) return null
    const headers = new Headers()
    for (const name of SNAPSHOT_HEADERS) {
      if (metadata && metadata[name]) headers.set(name, metadata[name])
    }
    return new Response(value, { status: 200, headers })
  } catch (err) {
    return null
  }
}

// Restores the origin's own Cache-Control on the way out. The long max-age is
// an edge storage instruction and must not become the browser's.
function served(response, status) {
  const headers = new Headers(response.headers)
  headers.set('X-DT-Cache', status)
  const originCacheControl = headers.get(ORIGIN_CC)
  if (originCacheControl) headers.set('Cache-Control', originCacheControl)
  headers.delete(ORIGIN_CC)
  headers.delete(CACHED_AT)
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers
  })
}

export default {
  async fetch(request, env, ctx) {
    const visitorUrl = new URL(request.url)
    const visitorHost = visitorUrl.hostname
    const cacheable = request.method === 'GET'
    const cache = caches.default
    const cacheKey = cacheable ? new Request(visitorUrl.toString(), { method: 'GET' }) : null

    let cached = null
    if (cacheable) {
      try {
        cached = (await cache.match(cacheKey)) || null
      } catch (err) {
        cached = null
      }
      if (cached && ageOf(cached) < FRESH_SECONDS) return served(cached, 'HIT')
    }

    const url = new URL(request.url)
    url.hostname = env.ORIGIN_HOST

    const headers = new Headers(request.headers)
    headers.set('X-Tenant-Host', visitorHost)
    headers.set('X-Tenant-Proxy-Secret', env.PROXY_SECRET)
    headers.set('X-Forwarded-Proto', 'https')

    let response
    try {
      response = await fetch(new URL(url).toString(), {
        method: request.method,
        headers,
        body: request.method === 'GET' || request.method === 'HEAD' ? undefined : request.body,
        // Redirects belong to the visitor. Following them here would resolve a
        // dealer's canonical-host redirect against the origin hostname instead
        // of theirs.
        redirect: 'manual'
      })
    } catch (err) {
      if (cached) return served(cached, 'STALE-ORIGIN-UNREACHABLE')
      const snapshot = cacheable ? await snapshotRead(env, visitorUrl.toString()) : null
      if (snapshot) return served(snapshot, 'SNAPSHOT-ORIGIN-UNREACHABLE')
      throw err
    }

    if (response.status >= 500) {
      if (cached) return served(cached, 'STALE-ORIGIN-ERROR')
      const snapshot = cacheable ? await snapshotRead(env, visitorUrl.toString()) : null
      if (snapshot) return served(snapshot, 'SNAPSHOT-ORIGIN-ERROR')
    }

    // A redirect naming the Render hostname would walk the visitor off the
    // dealer's domain and onto ours.
    const location = response.headers.get('Location')
    if (location && location.includes(env.ORIGIN_HOST)) {
      const fixed = new Headers(response.headers)
      fixed.set('Location', location.replaceAll(env.ORIGIN_HOST, visitorHost))
      return new Response(response.body, {
        status: response.status,
        statusText: response.statusText,
        headers: fixed
      })
    }

    // Set-Cookie means the response was personalised, so it is not shared.
    const storable = cacheable && response.status === 200 && !response.headers.get('Set-Cookie')
    if (storable) {
      const toStore = new Headers(response.headers)
      toStore.set(CACHED_AT, String(Date.now()))
      const originCacheControl = response.headers.get('Cache-Control')
      if (originCacheControl) toStore.set(ORIGIN_CC, originCacheControl)
      toStore.set('Cache-Control', `public, max-age=${FRESH_SECONDS + STALE_IF_ERROR_SECONDS}`)

      const body = await response.arrayBuffer()
      ctx.waitUntil(cache.put(cacheKey, new Response(body, {
        status: response.status,
        statusText: response.statusText,
        headers: toStore
      })))
      snapshotWrite(env, ctx, visitorUrl.toString(), response, body)

      return served(new Response(body, {
        status: response.status,
        statusText: response.statusText,
        headers: response.headers
      }), 'MISS')
    }

    return response
  }
}

/**
 * tenant-host-proxy-staging
 *
 * The staging twin of tenant-host-proxy. Same job: Render rejects any Host it
 * does not recognise as a registered domain, so the real hostname cannot travel
 * in Host and is carried in a header instead. Rails reads it back in
 * Websites::RequestHost, which trusts the header only when the shared secret
 * matches, because otherwise anyone hitting the Render hostname directly could
 * claim to be any dealer's domain and be served that dealer's site.
 *
 * This exists as a SECOND script rather than a branch inside the production one
 * because the production Worker is what every live dealer domain depends on,
 * and it is not worth editing to serve staging. Routes are bound per hostname,
 * so the two never overlap: production hosts keep the production script and
 * only *-staging.mydealertide.com hosts are bound to this one.
 *
 * Bind with: CLOUDFLARE_WORKER_SCRIPT=tenant-host-proxy-staging on the staging
 * service, which Websites::SubdomainRouteProvisioner passes to
 * CloudflareSaasService#create_worker_route.
 *
 * Secrets (Workers > this script > Settings > Variables), both encrypted:
 *   ORIGIN_HOST    renterinsight-api-staging.onrender.com
 *   PROXY_SECRET   must equal TENANT_PROXY_SECRET on the staging Rails service
 */
export default {
  async fetch(request, env) {
    const originHost = env.ORIGIN_HOST
    if (!originHost) {
      return new Response('Proxy is not configured.', { status: 502 })
    }

    const incoming = new URL(request.url)
    const visitorHost = incoming.hostname

    const target = new URL(request.url)
    target.hostname = originHost
    target.protocol = 'https:'
    target.port = ''

    const headers = new Headers(request.headers)
    headers.set('Host', originHost)
    headers.set('X-Tenant-Host', visitorHost)
    headers.set('X-Tenant-Proxy-Secret', env.PROXY_SECRET || '')
    // The visitor asked over HTTPS at the edge even though this hop is its own
    // connection; without it Rails can decide it is on http and redirect.
    headers.set('X-Forwarded-Proto', 'https')
    headers.set('X-Forwarded-Host', visitorHost)

    // redirect: 'manual' so a 301 from Rails reaches the browser as a 301
    // against the visitor's hostname, rather than being followed here and
    // silently resolved against the Render hostname.
    return fetch(new Request(target.toString(), {
      method: request.method,
      headers,
      body: request.body,
      redirect: 'manual'
    }))
  }
}

# frozen_string_literal: true

# Platform brand kernel — the small, stable set of identity fields (name,
# support/from email, public URLs, logo) used in system-sent emails, prose,
# and public-facing links. Layers optional per-tenant overrides (whitelabel)
# over the platform-wide defaults.
#
# Visual branding (colors, fonts, per-tenant logos) still flows through the
# existing Setting-backed branding waterfall in SettingsController; this
# object is the single source of truth for _text_ identity.
#
#   Brand.current                        # platform-only
#   Brand.current(company: @company)     # allows per-tenant override if set
class Brand
  ATTRIBUTES = %i[
    name
    short_name
    support_email
    sales_email
    from_email
    from_name
    website_url
    app_url
    privacy_url
    terms_url
    subdomain_root
    site_host_root
    logo_url
    favicon_url
  ].freeze

  attr_reader(*ATTRIBUTES)

  def self.current(company: nil)
    new(company: company)
  end

  # Frontend app URL for user-facing links (login, deep links, unsubscribe
  # page). Resolves through the kernel, so ENV supplies the default and a
  # Platform Admin override wins — one place to change, always accurate.
  #
  # This is the *frontend* host. Tracking endpoints (pixel, /t, /u) live on
  # the API and must use Messaging::TrackingUrl instead; conflating the two
  # is what silently killed open tracking.
  #
  # Rescues because callers are mailers and notification services where a
  # settings-lookup failure must not take down the send.
  def self.app_url(company: nil)
    current(company: company).app_url.presence || default_app_url
  rescue StandardError
    default_app_url
  end

  def self.default_app_url
    Rails.env.production? ? 'https://app.dealertide.com' : 'https://localhost:5173'
  end

  # Platform sender identity, for the last-resort fallback in mailers,
  # services and jobs that first look for a company/location/platform
  # communications config. Previously each of those hardcoded its own
  # 'noreply@...' literal, so changing the platform From address in Platform
  # Admin left a dozen of them still sending under the old brand.
  #
  # Falls back to PlatformSetting.default_general — which is pure ENV and
  # never touches the database — so there is no new literal here and the
  # rescue path stays safe when the settings lookup itself fails.
  def self.from_email(company: nil)
    current(company: company).from_email.presence || default_general_value(:fromEmail)
  rescue StandardError
    default_general_value(:fromEmail)
  end

  def self.from_name(company: nil)
    current(company: company).from_name.presence || default_general_value(:fromName)
  rescue StandardError
    default_general_value(:fromName)
  end

  def self.default_general_value(key)
    PlatformSetting.default_general[key]
  end

  def initialize(company: nil)
    platform = PlatformSetting.general
    branding = platform_branding_hash
    overrides = company_overrides(company)

    @name           = resolve(overrides, :name,           platform[:platformName])
    @short_name     = resolve(overrides, :short_name,     platform[:shortName]) || @name
    @support_email  = resolve(overrides, :support_email,  platform[:supportEmail])
    @sales_email    = resolve(overrides, :sales_email,    platform[:salesEmail])
    @from_email     = resolve(overrides, :from_email,     platform[:fromEmail])
    @from_name      = resolve(overrides, :from_name,      platform[:fromName]) || @name
    @website_url    = resolve(overrides, :website_url,    platform[:websiteUrl])
    @app_url        = resolve(overrides, :app_url,        platform[:appUrl])
    @privacy_url    = resolve(overrides, :privacy_url,    platform[:privacyUrl])
    @terms_url      = resolve(overrides, :terms_url,      platform[:termsUrl])
    @subdomain_root = resolve(overrides, :subdomain_root, platform[:subdomainRoot])
    # Falls back to subdomain_root so an environment that has not set the new
    # value behaves exactly as it did before this field existed.
    @site_host_root = resolve(overrides, :site_host_root, platform[:siteHostRoot]).presence || @subdomain_root
    @logo_url       = resolve(overrides, :logo_url,       branding[:logo])
    # The tab icon, from the same branding waterfall as the logo. Stored under
    # either spelling because SettingsController normalises faviconUrl into
    # favicon on write but older records only carry one of them.
    @favicon_url    = unquote(resolve(overrides, :favicon_url, branding[:faviconUrl] || branding[:favicon]))
  end

  def to_h
    ATTRIBUTES.each_with_object({}) { |a, h| h[a] = public_send(a) }
  end

  private

  def resolve(overrides, key, fallback)
    override = overrides[key]
    override.respond_to?(:presence) ? (override.presence || fallback) : (override || fallback)
  end

  # The stored favicon arrives wrapped in literal quotes, from a value that was
  # JSON-encoded once too often on the way in. Left alone it lands inside an
  # href and the browser requests a URL that does not exist, which is exactly
  # why an uploaded icon never appeared.
  def unquote(value)
    text = value.to_s.strip
    return nil if text.blank?

    text.gsub(/\A["']|["']\z/, '').presence
  end

  def platform_branding_hash
    raw = PlatformSetting.branding
    raw.is_a?(Hash) ? raw.symbolize_keys : {}
  rescue StandardError
    {}
  end

  # Per-tenant overrides live on Company#branding_overrides (JSONB). The column
  # isn't required to exist yet — resolver degrades to platform-only when
  # absent, so shipping the kernel doesn't block on a schema change.
  def company_overrides(company)
    return {} if company.nil?
    return {} unless company.respond_to?(:branding_overrides)
    raw = company.branding_overrides
    return {} if raw.blank?
    raw.deep_symbolize_keys
  rescue StandardError
    {}
  end
end

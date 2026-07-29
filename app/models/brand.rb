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
    logo_url
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
    @logo_url       = resolve(overrides, :logo_url,       branding[:logo])
  end

  def to_h
    ATTRIBUTES.each_with_object({}) { |a, h| h[a] = public_send(a) }
  end

  private

  def resolve(overrides, key, fallback)
    override = overrides[key]
    override.respond_to?(:presence) ? (override.presence || fallback) : (override || fallback)
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

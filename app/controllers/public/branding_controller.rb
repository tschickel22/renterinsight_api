# frozen_string_literal: true

# A dealer's public identity, for the pre-auth pages their own visitors land on.
#
# Their website sends people to our sign-in, and arriving at a page wearing our
# logo reads as having been handed off to a stranger. This returns only what is
# already on every page of their public site — the name, the logo and the brand
# colour — so the sign-in can look like the place the visitor just left.
#
# Public by necessity and by nature: nobody is signed in yet, and none of this
# is private. Deliberately narrow, so it cannot become a way to enumerate
# anything else about a company.
class Public::BrandingController < ApplicationController
  skip_before_action :authenticate, raise: false
  skip_before_action :set_company_scope, raise: false
  skip_before_action :set_current_attributes, raise: false

  # Branding settings are written by several vintages of UI and by the website
  # builder, so the logo lands under whichever of these that writer used.
  # resolve_branding_for_inventory fills 'logo' in particular, which is why
  # reading only 'logo_url' returned a name with no mark and every embedded
  # sign-in wore ours.
  LOGO_KEYS = %w[logo_url logoUrl logo].freeze

  def show
    company = Company.find_by(id: params[:company_id])
    return render json: { branding: nil }, status: :ok if company.nil?

    source = brand_source(company)

    render json: {
      branding: {
        name: lookup(source, %w[company_name name]).presence || company.name,
        logo_url: lookup(source, LOGO_KEYS),
        primary_color: lookup(source, %w[primary_color primaryColor])
      }.compact
    }
  rescue StandardError => e
    # A sign-in page must render whatever happens here; it falls back to ours.
    Rails.logger.warn("[Public::Branding] #{e.class}: #{e.message}")
    render json: { branding: nil }, status: :ok
  end

  private

  # Whose identity the visitor is actually looking at, most specific first.
  #
  # A demo wears the scanned prospect's brand rather than the lot company's, so
  # asking the tenant would answer with the wrong dealer entirely. A committed
  # site carries its own brand, which is the one on the page the visitor just
  # left. Only when neither says anything do we fall back to the company's own
  # settings.
  def brand_source(company)
    demo_brand.presence || website_brand(company).presence ||
      company.resolve_branding_for_inventory
  end

  # The demo being shown. Proven by its own preview token, which is already
  # public for that demo and unguessable, so this grants nothing new.
  def demo_brand
    token = params[:demo_token].presence
    return {} if token.blank?

    profile = SiteContentProfile.find_by(preview_token: token)
    return {} unless profile&.shareable?

    profile.profile.to_h['brand'].to_h
  end

  # The site the visitor came from. Scoped through the company, so an id in the
  # query string cannot reach another tenant's site.
  def website_brand(company)
    id = params[:website_id].presence
    return {} if id.blank?

    company.websites.find_by(id: id)&.brand.to_h
  end

  def lookup(source, keys)
    hash = source.to_h
    keys.filter_map { |key| hash[key].presence || hash[key.to_sym].presence }.first
  end
end

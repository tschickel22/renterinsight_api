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

  def show
    company = Company.find_by(id: params[:company_id])
    return render json: { branding: nil }, status: :ok if company.nil?

    branding = company.resolve_branding_for_inventory

    render json: {
      branding: {
        name: company.name,
        logo_url: branding['logo_url'] || branding[:logo_url],
        primary_color: branding['primary_color'] || branding[:primary_color]
      }.compact
    }
  rescue StandardError => e
    # A sign-in page must render whatever happens here; it falls back to ours.
    Rails.logger.warn("[Public::Branding] #{e.class}: #{e.message}")
    render json: { branding: nil }, status: :ok
  end
end

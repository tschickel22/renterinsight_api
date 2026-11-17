# frozen_string_literal: true

# Where TrueBuild may be offered. Nowhere when the dealer turned the website
# designer off. Otherwise on a dealer's DealerTide site always; on the
# dealer's own website (the inventory embed, or a page built on the public
# API) only with the add-on, which Tom grants dealer by dealer: buyers are
# meant to design on the DealerTide site.
#
# A DealerTide site says so by sending one of the dealer's own website ids
# (website_id). Anything else with the public inventory token is treated as
# the dealer's own website. Without the add-on it gets no designable flags,
# the designer endpoints refuse it, and a home that could be designed points
# to its page on the DealerTide site instead.
#
# A shared demo (a scanned site we are proposing) is a DealerTide site too:
# it sends its preview token (demo_token), and counts for the one lot that
# demo shows (DemoInventoryResolver). Nothing a buyer designs there is saved.
module TruebuildReach
  extend ActiveSupport::Concern

  EMBED_MODULE = 'sales.truebuild_embed' # TrueBuild on your own website

  private

  def dealertide_site_request?
    return @dealertide_site_request if defined?(@dealertide_site_request)

    @dealertide_site_request = (params[:website_id].present? && @company.websites.exists?(id: params[:website_id].to_i)) ||
                               demo_request?
  end

  # Proven by the demo's preview token, which only a platform admin can make
  # and can withdraw, and only for the lot that demo borrows.
  def demo_request?
    return @demo_request if defined?(@demo_request)

    token = params[:demo_token].presence
    profile = token && SiteContentProfile.find_by(preview_token: token.to_s)
    @demo_request = !!(profile&.shareable? &&
                       SiteProfiles::DemoInventoryResolver.config_for_profile(profile)&.dig('company_id') == @company.id)
  end

  def truebuild_reachable?
    return false unless website_designer?

    dealertide_site_request? || @company.has_module?(EMBED_MODULE)
  end

  # The dealer's own switch (TrueBuild pricing settings): off, no website
  # offers the designer, while the Deal Sheet and quotes still use TrueBuild.
  def website_designer?
    return @website_designer if defined?(@website_designer)

    @website_designer = DealerCatalogTerm.effective(@company, nil).website_designer != false
  end

  # The home on the dealer's live DealerTide site, for "Design this home on
  # our website", or nil when the dealer has no live site or no designer.
  def truebuild_site_url(vehicle = nil)
    return nil unless website_designer?

    site = @company.websites.where(status: :published).order(:id).find { |w| w.public_url.present? }
    return nil unless site

    vehicle ? "#{site.public_url}#{Websites::HomeUrl.path_for(vehicle)}" : site.public_url
  end
end

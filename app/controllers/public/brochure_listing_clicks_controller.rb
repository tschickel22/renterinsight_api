# frozen_string_literal: true

module Public
  # Records which home a brochure viewer clicked.
  #
  # Homes on the public brochure page open in place (BrochureRenderer's listing
  # tiles swap the selected listing client-side), so unlike the email's home
  # links there is no redirect for us to observe. The page posts here instead.
  #
  # Attribution comes from the `rt` token the recipient's brochure link put in
  # the URL. Without it the click still counts, it just counts anonymously —
  # which keeps a brochure shared on social from silently recording nothing.
  class BrochureListingClicksController < ApplicationController
    skip_before_action :authenticate, raise: false
    skip_before_action :set_company_scope, raise: false
    skip_before_action :set_current_attributes, raise: false

    # POST /b/:public_id/listing_click
    def create
      brochure = Brochure.public_brochures.find_by(public_id: params[:public_id])
      return head(:not_found) unless brochure

      # Scoped to the brochure's own homes, so the endpoint can't be used to
      # attach clicks to arbitrary inventory.
      vehicle = brochure.vehicles.find_by(id: params[:vehicle_id])
      return head(:not_found) unless vehicle

      entity_type, entity_id = recipient_for(brochure)

      link = TrackedLink.for_brochure_listing!(
        company:     brochure.company,
        brochure:    brochure,
        vehicle_id:  vehicle.id,
        url:         "#{brochure.public_url(public_base_url)}?listing=#{vehicle.id}",
        entity_type: entity_type,
        entity_id:   entity_id
      )
      link.record_click!(ip_address: request.remote_ip, user_agent: request.user_agent)

      head :no_content
    rescue => e
      # Analytics must never break the page the customer is reading.
      Rails.logger.warn "[Brochure] listing click failed: #{e.message}"
      head :no_content
    end

    private

    # The `rt` token identifies the brochure link we mailed. It only counts for
    # the brochure it was minted for, so a token can't be replayed against
    # someone else's collection.
    def recipient_for(brochure)
      token = params[:rt].presence
      return [nil, nil] unless token

      link = TrackedLink.brochure_opens.find_by(token: token, source_id: brochure.id)
      return [nil, nil] unless link

      [link.entity_type, link.entity_id]
    end

    def public_base_url
      ENV['FRONTEND_URL'] || ENV['API_BASE_URL'] || 'http://localhost:3000'
    end
  end
end

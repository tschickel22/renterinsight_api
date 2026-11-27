# frozen_string_literal: true

# Vacancies a landlord published in Renter Insight, for the rental listings
# block on their DealerTide website.
#
# Public because the visitor is anonymous, and safe to be: it returns only
# what Renter Insight's own public listing page already shows, through
# RenterInsight::PublicListings, which names every field it lets out.
class Public::RentalListingsController < ApplicationController
  skip_before_action :authenticate, raise: false
  skip_before_action :set_company_scope, raise: false
  skip_before_action :set_current_attributes, raise: false

  SOURCES = %w[renter_insight].freeze

  def index
    source = params[:source].presence || 'renter_insight'
    unless SOURCES.include?(source) && RenterInsight::PublicListings.valid_id?(params[:listing])
      return render json: { error: 'Unknown listing' }, status: :bad_request
    end

    result = RenterInsight::PublicListings.fetch(params[:listing])
    # Shared caches may hold it briefly; vacancies change a few times a month.
    response.headers['Cache-Control'] = 'public, max-age=300'
    # An unreadable source is an empty list to the visitor, never an error page.
    render json: (result || { listings: [], property: nil }).merge(available: !result.nil?)
  end
end

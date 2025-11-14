# frozen_string_literal: true

module Public
  class SyndicationFeedsController < ApplicationController
    skip_before_action :authenticate
    before_action :set_partner
    before_action :verify_token
    before_action :set_cors_headers

    # GET /public/feeds/:id?token=xxx
    def show
      listings = fetch_listings

      case @partner.format
      when 'mits_xml'
        render_mits_feed(listings)
      when 'json'
        render_json_feed(listings)
      when 'xml'
        render_xml_feed(listings)
      else
        render json: { error: 'Invalid feed format' }, status: :bad_request
      end
    end

    private

    def set_partner
      @partner = SyndicationPartner.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Syndication partner not found' }, status: :not_found
    end

    def verify_token
      provided_token = params[:token]
      
      unless provided_token.present? && provided_token == @partner.feed_token
        render json: { error: 'Unauthorized - Invalid token' }, status: :unauthorized
      end
    end

    def set_cors_headers
      headers['Access-Control-Allow-Origin'] = '*'
      headers['Access-Control-Allow-Methods'] = 'GET, OPTIONS'
      headers['Access-Control-Allow-Headers'] = 'Content-Type'
    end

    def fetch_listings
      company = @partner.company
      
      Rails.logger.info "=== SYNDICATION FEED DEBUG ==="
      Rails.logger.info "Partner: #{@partner.name} (ID: #{@partner.id})"
      Rails.logger.info "Format: #{@partner.format}"
      Rails.logger.info "Listing Types Filter: #{@partner.listing_types.inspect}"
      
      listings = company.listings.published.includes(:vehicle)
      Rails.logger.info "After published filter: #{listings.count} listings"
      
      # Log all listings before filtering
      listings.each do |listing|
        Rails.logger.info "  - Listing #{listing.id}: offer_type=#{listing.offer_type}, vehicle_type=#{listing.vehicle.listing_type}"
      end

      # Filter by partner's listing types (rv vs manufactured_home)
      if @partner.listing_types.present?
        vehicle_ids = company.vehicles.where(listing_type: @partner.listing_types).pluck(:id)
        listings = listings.where(vehicle_id: vehicle_ids)
        Rails.logger.info "After listing_types filter: #{listings.count} listings"
      end

      # Filter by offer_type based on feed format
      case @partner.format
      when 'mits_xml'
        # MITS/Zillow: Only rental listings
        listings = listings.where(offer_type: ['rent', 'both'])
        Rails.logger.info "After MITS rental filter: #{listings.count} listings"
      when 'json', 'xml'
        # MH Village: Only manufactured homes (no RVs)
        # Already filtered by listing_types if configured, but enforce it
        vehicle_ids = company.vehicles.where(listing_type: 'manufactured_home').pluck(:id)
        listings = listings.where(vehicle_id: vehicle_ids)
        Rails.logger.info "After MH Village manufactured_home filter: #{listings.count} listings"
      end
      
      Rails.logger.info "Final listing count: #{listings.count}"
      Rails.logger.info "=== END DEBUG ==="

      listings
    end

    def render_mits_feed(listings)
      company = @partner.company
      builder = Syndication::MitsFeedBuilder.new(company: company, partner: @partner, listings: listings)
      xml = builder.build_xml

      render xml: xml, content_type: 'application/xml'
    end

    def render_json_feed(listings)
      company = @partner.company
      builder = Syndication::MhVillageFeedBuilder.new(company: company, partner: @partner, listings: listings)
      json_data = builder.build_json

      render json: json_data, content_type: 'application/json'
    end

    def render_xml_feed(listings)
      company = @partner.company
      builder = Syndication::MhVillageFeedBuilder.new(company: company, partner: @partner, listings: listings)
      xml = builder.build_xml

      render xml: xml, content_type: 'application/xml'
    end
  end
end

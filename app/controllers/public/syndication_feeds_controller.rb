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
      listings = company.listings.published.includes(:vehicle)

      # Filter by partner's listing types
      if @partner.listing_types.present?
        vehicle_ids = company.vehicles.where(listing_type: @partner.listing_types).pluck(:id)
        listings = listings.where(vehicle_id: vehicle_ids)
      end

      # Filter by offer type based on format
      if @partner.uses_mits_format?
        listings = listings.where(offer_type: ['rent', 'both'])
      elsif @partner.uses_mh_village_format?
        listings = listings.where(offer_type: ['sale', 'both'])
      end

      listings
    end

    def render_mits_feed(listings)
      company = @partner.company
      builder = Syndication::MitsFeedBuilder.new(company, listings)
      xml = builder.build_xml

      render xml: xml, content_type: 'application/xml'
    end

    def render_json_feed(listings)
      company = @partner.company
      builder = Syndication::MhVillageFeedBuilder.new(company, listings)
      json_data = builder.build_json

      render json: json_data, content_type: 'application/json'
    end

    def render_xml_feed(listings)
      company = @partner.company
      builder = Syndication::MhVillageFeedBuilder.new(company, listings)
      xml = builder.build_xml

      render xml: xml, content_type: 'application/xml'
    end
  end
end

# frozen_string_literal: true

module Public
  class SyndicationFeedsController < ApplicationController
    skip_before_action :authenticate
    before_action :set_partner
    before_action :verify_token
    before_action :require_active_partner
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
      
      unless provided_token.present? && @partner.feed_token.present? &&
             ActiveSupport::SecurityUtils.secure_compare(provided_token.to_s, @partner.feed_token.to_s)
        render json: { error: 'Unauthorized - Invalid token' }, status: :unauthorized
      end
    end

    # A partner switched off by a platform admin serves nothing, so the
    # listing site stops receiving homes the moment it is disabled.
    def require_active_partner
      return if @partner.active?

      render json: { error: 'Syndication partner not found' }, status: :not_found
    end

    def set_cors_headers
      headers['Access-Control-Allow-Origin'] = '*'
      headers['Access-Control-Allow-Methods'] = 'GET, OPTIONS'
      headers['Access-Control-Allow-Headers'] = 'Content-Type'
    end

    def fetch_listings
      # PLATFORM-WIDE FEED: partners are set up once by platform admins and the
      # feed carries every dealer's published listings. Each dealer's own
      # account number at the partner is resolved per listing company by the
      # feed builders (SyndicationPartner#dealer_identifier_for).
      listings = Listing.published.includes(:vehicle, :company)

      # Filter by partner's listing types (rv vs manufactured_home)
      if @partner.listing_types.present?
        listings = listings.joins(:vehicle).where(vehicles: { listing_type: @partner.listing_types })
      end

      # Filter by offer_type based on feed format
      case @partner.format
      when 'mits_xml'
        # MITS/Zillow: Only rental listings
        listings = listings.where(offer_type: ['rent', 'both'])
      when 'json', 'xml'
        if @partner.partner_type == 'rvt'
          # RVT.com: RVs only, sales only
          listings = listings.joins(:vehicle).where(vehicles: { listing_type: 'rv' })
          listings = listings.where(offer_type: ['sale', 'both'])
        else
          # MH Village: Only manufactured homes (no RVs), only sales
          listings = listings.joins(:vehicle).where(vehicles: { listing_type: 'manufactured_home' })
          listings = listings.where(offer_type: ['sale', 'both'])
        end
      end

      Rails.logger.info "[SyndicationFeed] partner=#{@partner.id} format=#{@partner.format} listings=#{listings.size}"
      listings
    end

    def render_mits_feed(listings)
      # Platform-wide feed - no single company, listings grouped by company in XML
      builder = Syndication::MitsFeedBuilder.new(company: nil, partner: @partner, listings: listings)
      xml = builder.build_xml

      render xml: xml, content_type: 'application/xml'
    end

    def render_json_feed(listings)
      # Platform-wide feed - no single company, listings grouped by company in JSON
      # Support both MH Village and RVT.com feeds
      if @partner.partner_type == 'rvt'
        builder = Syndication::RvtFeedBuilder.new(company: nil, partner: @partner, listings: listings)
      else
        builder = Syndication::MhVillageFeedBuilder.new(company: nil, partner: @partner, listings: listings)
      end
      
      json_data = builder.build_json

      render json: json_data, content_type: 'application/json'
    end

    def render_xml_feed(listings)
      # Platform-wide feed - no single company, listings grouped by company in XML
      # Support both MH Village and RVT.com feeds
      if @partner.partner_type == 'rvt'
        builder = Syndication::RvtFeedBuilder.new(company: nil, partner: @partner, listings: listings)
        xml = builder.build_xml
      else
        builder = Syndication::MhVillageFeedBuilder.new(company: nil, partner: @partner, listings: listings)
        xml = builder.build_xml
      end

      render xml: xml, content_type: 'application/xml'
    end
  end
end

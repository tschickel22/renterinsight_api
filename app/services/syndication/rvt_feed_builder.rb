# frozen_string_literal: true

module Syndication
  class RvtFeedBuilder
    attr_reader :company, :partner, :listings
    
    def initialize(company:, partner:, listings:)
      @company = company
      @partner = partner
      @listings = listings
    end
    
    def build_json
      # Platform-wide feed: Group listings by company
      if company.nil?
        dealers = listings.group_by(&:company).map do |company, company_listings|
          {
            dealer_name: company.name,
            dealer_phone: company_phone_for(company),
            dealer_id: partner.account_id || company.id,
            total_listings: company_listings.count,
            listings: company_listings.map { |listing| listing_to_json(listing) }
          }
        end
        
        {
          feed_generated_at: Time.current.iso8601,
          dealers: dealers
        }.to_json
      else
        # Single company feed (legacy)
        {
          feed_generated_at: Time.current.iso8601,
          dealer_name: company.name,
          dealer_phone: company_phone,
          dealer_id: partner.account_id || company.id,
          total_listings: listings.count,
          listings: listings.map { |listing| listing_to_json(listing) }
        }.to_json
      end
    end
    
    def build_xml
      require 'builder'
      
      xml = Builder::XmlMarkup.new(indent: 2)
      xml.instruct! :xml, version: '1.0', encoding: 'UTF-8'
      
      xml.RVTFeed do
        xml.FeedGeneratedAt Time.current.iso8601
        
        # Platform-wide feed: Group listings by company
        if company.nil?
          listings.group_by(&:company).each do |company, company_listings|
            xml.Dealer do
              xml.DealerName company.name
              xml.DealerPhone company_phone_for(company)
              xml.DealerIdentifyer partner.account_id || company.id
              xml.TotalListings company_listings.count
              
              xml.Listings do
                company_listings.each do |listing|
                  add_listing_xml(xml, listing)
                end
              end
            end
          end
        else
          # Single company feed (legacy)
          xml.DealerName company.name
          xml.DealerPhone company_phone
          xml.DealerIdentifyer partner.account_id || company.id
          xml.TotalListings listings.count
          
          xml.Listings do
            listings.each do |listing|
              add_listing_xml(xml, listing)
            end
          end
        end
      end
      
      xml.target!
    end
    
    private
    
    def listing_to_json(listing)
      vehicle = listing.vehicle
      
      {
        # Basic Info
        dealername: listing.company.name,
        DealerIdentifyer: partner.account_id || listing.company.id,
        Phone: company_phone_for(listing.company),
        UniqueID: listing.id,
        StockNumber: vehicle.inventory_id,
        
        # Vehicle Details
        Year: vehicle.year,
        MakeName: vehicle.make,
        Brand: vehicle.make,
        ModelName: vehicle.model,
        MfrSerialNumber: vehicle.vin,
        Condition: vehicle.condition&.capitalize,
        
        # RV Specs
        Class: vehicle.rv_class,
        Length: vehicle.length,
        Weight: vehicle.weight,
        FuelType: vehicle.fuel_type,
        Mileage: vehicle.mileage,
        ExteriorColor: vehicle.exterior_color,
        
        # NEW RVT.com Syndication Fields
        EngineMake: vehicle.engine_make,
        EngineType: vehicle.engine_type,
        SleepingCapacity: vehicle.sleeping_capacity,
        NumAirConditioners: vehicle.num_air_conditioners,
        Slideouts: vehicle.slideouts,
        Awnings: vehicle.awnings,
        WaterCapacity: vehicle.fresh_water_capacity,
        LevelingJacks: boolean_to_yes_no(vehicle.leveling_jacks),
        SelfContained: boolean_to_yes_no(vehicle.self_contained),
        
        # Pricing
        Price: listing.sale_price&.to_f,
        
        # Description & Marketing
        Description: listing.description,
        OverlayText: vehicle.overlay_text,
        
        # URLs
        ItemUrl: generate_listing_url(listing),
        YoutubeVideoURL: vehicle.video_url,
        VirtualTour: vehicle.virtual_tour_url,
        
        # Location
        City: vehicle.location_city,
        StateCode: vehicle.location_state,
        ZipCode: vehicle.location_zip,
        CountryCode: 'US'
      }.merge(generate_photo_hash(vehicle)).compact
    end
    
    def add_listing_xml(xml, listing)
      vehicle = listing.vehicle
      
      xml.Listing do
        # Basic Info
        xml.dealername listing.company.name
        xml.DealerIdentifyer partner.account_id || listing.company.id
        xml.Phone company_phone_for(listing.company)
        xml.UniqueID listing.id
        xml.StockNumber vehicle.inventory_id
        
        # Vehicle Details
        xml.Year vehicle.year if vehicle.year.present?
        xml.MakeName vehicle.make if vehicle.make.present?
        xml.Brand vehicle.make if vehicle.make.present?
        xml.ModelName vehicle.model if vehicle.model.present?
        xml.MfrSerialNumber vehicle.vin if vehicle.vin.present?
        xml.Condition vehicle.condition&.capitalize if vehicle.condition.present?
        
        # RV Specs
        xml.Class vehicle.rv_class if vehicle.rv_class.present?
        xml.Length vehicle.length if vehicle.length.present?
        xml.Weight vehicle.weight if vehicle.weight.present?
        xml.FuelType vehicle.fuel_type if vehicle.fuel_type.present?
        xml.Mileage vehicle.mileage if vehicle.mileage.present?
        xml.ExteriorColor vehicle.exterior_color if vehicle.exterior_color.present?
        
        # NEW RVT.com Syndication Fields
        xml.EngineMake vehicle.engine_make if vehicle.engine_make.present?
        xml.EngineType vehicle.engine_type if vehicle.engine_type.present?
        xml.SleepingCapacity vehicle.sleeping_capacity if vehicle.sleeping_capacity.present?
        xml.NumAirConditioners vehicle.num_air_conditioners if vehicle.num_air_conditioners.present?
        xml.Slideouts vehicle.slideouts if vehicle.slideouts.present?
        xml.Awnings vehicle.awnings if vehicle.awnings.present?
        xml.WaterCapacity vehicle.fresh_water_capacity if vehicle.fresh_water_capacity.present?
        xml.LevelingJacks boolean_to_yes_no(vehicle.leveling_jacks) unless vehicle.leveling_jacks.nil?
        xml.SelfContained boolean_to_yes_no(vehicle.self_contained) unless vehicle.self_contained.nil?
        
        # Pricing
        xml.Price listing.sale_price&.to_f if listing.sale_price.present?
        
        # Description & Marketing
        if listing.description.present?
          xml.Description do
            xml.cdata! listing.description
          end
        end
        xml.OverlayText vehicle.overlay_text if vehicle.overlay_text.present?
        
        # URLs
        xml.ItemUrl generate_listing_url(listing)
        xml.YoutubeVideoURL vehicle.video_url if vehicle.video_url.present?
        xml.VirtualTour vehicle.virtual_tour_url if vehicle.virtual_tour_url.present?
        
        # Location
        xml.City vehicle.location_city if vehicle.location_city.present?
        xml.StateCode vehicle.location_state if vehicle.location_state.present?
        xml.ZipCode vehicle.location_zip if vehicle.location_zip.present?
        xml.CountryCode 'US'
        
        # Photos (up to 31)
        if vehicle.images.present?
          vehicle.images.first(31).each_with_index do |image, index|
            image_url = image.is_a?(Hash) ? (image['url'] || image[:url]) : image
            next if image_url.blank?
            
            xml.tag!("Photo#{index + 1}", image_url)
          end
        end
      end
    end
    
    # Helper methods
    
    def generate_photo_hash(vehicle)
      photos = vehicle.images || []
      photo_hash = {}
      
      photos.first(31).each_with_index do |image, index|
        image_url = image.is_a?(Hash) ? (image['url'] || image[:url]) : image
        next if image_url.blank?
        
        photo_hash["Photo#{index + 1}"] = image_url
      end
      
      photo_hash
    end
    
    def boolean_to_yes_no(value)
      return nil if value.nil?
      value ? 'Yes' : 'No'
    end
    
    def generate_listing_url(listing)
      # Use environment-appropriate base URL
      base_url = if Rails.env.development?
        'https://localhost:5173'
      elsif Rails.env.staging?
        ENV.fetch('PUBLIC_LISTING_BASE_URL', 'https://staging.crm.landlordinsight.com')
      else
        ENV.fetch('PUBLIC_LISTING_BASE_URL', 'https://crm.landlordinsight.com')
      end
      
      "#{base_url}/listings/#{listing.id}"
    end
    
    def company_phone
      company_phone_for(company)
    end
    
    def company_phone_for(comp)
      # Company doesn't have phone - use first user or default
      comp.users.first&.phone || '123-456-7890'
    end
  end
end

# frozen_string_literal: true

module Syndication
  class MhVillageFeedBuilder
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
            dealer_id: partner.account_id || company.id,
            dealer_name: company.name,
            contact_email: partner.lead_email || company_email_for(company),
            listings: company_listings.map { |listing| listing_to_json(listing) }
          }
        end
        
        { dealers: dealers }.to_json
      else
        # Single company feed (legacy)
        {
          dealer_id: partner.account_id || company.id,
          dealer_name: company.name,
          contact_email: partner.lead_email || company_email,
          listings: listings.map { |listing| listing_to_json(listing) }
        }.to_json
      end
    end
    
    def build_xml
      require 'builder'
      
      xml = Builder::XmlMarkup.new(indent: 2)
      xml.instruct! :xml, version: '1.0', encoding: 'UTF-8'
      
      xml.Listings do
        # Platform-wide feed: Group listings by company
        if company.nil?
          listings.group_by(&:company).each do |company, company_listings|
            xml.Dealer do
              xml.DealerID partner.account_id || company.id
              xml.DealerName company.name
              xml.ContactEmail partner.lead_email || company_email_for(company)
              
              company_listings.each do |listing|
                add_listing_xml(xml, listing)
              end
            end
          end
        else
          # Single company feed (legacy)
          xml.DealerID partner.account_id || company.id
          xml.DealerName company.name
          xml.ContactEmail partner.lead_email || company_email
          
          listings.each do |listing|
            add_listing_xml(xml, listing)
          end
        end
      end
      
      xml.target!
    end
    
    private
    
    def listing_contact_email(listing)
      # Three-tier fallback: Listing override → Location → Company
      listing.contact_email.presence || 
        location_email(listing) || 
        company_email_for(listing.company)
    end
    
    def listing_contact_phone(listing)
      # Three-tier fallback: Listing override → Location → Company
      listing.contact_phone.presence || 
        location_phone(listing) || 
        company_phone_for(listing.company)
    end
    
    def listing_seller_name(listing)
      # Three-tier fallback: Listing override → Location → Company
      result = listing.seller_name.presence || 
        location_name(listing) || 
        listing.company.name
      
      # DEBUG: Log what we're returning
      Rails.logger.info "[MH Village Feed] Listing ##{listing.id}: seller_name='#{result}' (location_name='#{location_name(listing)}', company='#{listing.company.name}')"
      
      result
    end
    
    # Location-level info
    
    def location_email(listing)
      listing.vehicle&.location&.email
    end
    
    def location_phone(listing)
      listing.vehicle&.location&.phone
    end
    
    def location_name(listing)
      listing.vehicle&.location&.name
    end
    
    def listing_to_json(listing)
      vehicle = listing.vehicle
      
      {
        listing_id: listing.id,
        stock_number: vehicle.inventory_id,
        
        # Basic info
        year: vehicle.year,
        make: vehicle.make,
        model: vehicle.model,
        serial_number: vehicle.serial_number,
        condition: vehicle.condition || 'used',
        
        # Dimensions
        length: vehicle.length,
        width: vehicle.width,
        square_feet: vehicle.square_feet,
        
        # Room counts
        bedrooms: vehicle.bedrooms,
        bathrooms: vehicle.bathrooms,
        
        # Pricing
        price: listing.sale_price&.to_f,
        rent_price: listing.rent_price&.to_f,
        rent_period: listing.rent_period,
        offer_type: listing.offer_type,
        
        # Location
        location: {
          address: vehicle.location_address,
          city: vehicle.location_city,
          state: vehicle.location_state,
          zip: vehicle.location_zip,
          latitude: listing.latitude,
          longitude: listing.longitude
        },
        
        # MH Village specific
        package_type: listing.package_type || 'package',
        location_type: listing.location_type || 'community',
        community_name: listing.community_name,
        lot_rent: listing.lot_rent&.to_f,
        
        # Details
        description: listing.description,
        features: listing.feature_list,
        
        # Images
        images: vehicle.images || [],
        
        # Features (Yes/No format for MH Village)
        has_garage: listing.has_garage? ? 'Yes' : 'No',
        has_fireplace: listing.has_fireplace? ? 'Yes' : 'No',
        has_deck: listing.has_deck? ? 'Yes' : 'No',
        has_shed: listing.has_shed? ? 'Yes' : 'No',
        has_appliances: listing.has_appliances? ? 'Yes' : 'No',
        has_ac: listing.has_ac? ? 'Yes' : 'No',
        is_furnished: listing.is_furnished? ? 'Yes' : 'No',
        pets_allowed: listing.pets_allowed? ? 'Yes' : 'No',
        
        # Availability
        financing_available: listing.financing_available || 'Contact for details',
        delivery_available: listing.delivery_available || 'Yes',
        setup_included: listing.setup_included || 'Contact for details',
        
        # Contact (uses Location → Company fallback)
        seller: {
          name: listing_seller_name(listing),
          phone: format_phone(listing_contact_phone(listing)),
          email: listing_contact_email(listing)
        },
        
        # Metadata
        status: listing.status,
        published_at: listing.published_at&.iso8601,
        updated_at: listing.updated_at.iso8601
      }
    end
    
    def add_listing_xml(xml, listing)
      vehicle = listing.vehicle
      
      xml.Listing do
        xml.ListingID listing.id
        xml.StockNumber vehicle.inventory_id
        
        # Basic info
        xml.Year vehicle.year
        xml.Make vehicle.make
        xml.Model vehicle.model
        xml.SerialNumber vehicle.serial_number
        xml.Condition vehicle.condition || 'used'
        
        # Dimensions
        xml.Length vehicle.length
        xml.Width vehicle.width
        xml.SquareFeet vehicle.square_feet
        
        # Room counts
        xml.Bedrooms vehicle.bedrooms
        xml.Bathrooms vehicle.bathrooms
        
        # Pricing
        xml.Price listing.sale_price&.to_f if listing.sale_price.present?
        xml.RentPrice listing.rent_price&.to_f if listing.rent_price.present?
        xml.RentPeriod listing.rent_period if listing.rent_period.present?
        xml.OfferType listing.offer_type
        
        # Location
        xml.Location do
          xml.Address vehicle.location_address
          xml.City vehicle.location_city
          xml.State vehicle.location_state
          xml.Zip vehicle.location_zip
          xml.Latitude listing.latitude if listing.latitude.present?
          xml.Longitude listing.longitude if listing.longitude.present?
        end
        
        # MH Village specific
        xml.PackageType listing.package_type || 'package'
        xml.LocationType listing.location_type || 'community'
        xml.CommunityName listing.community_name if listing.community_name.present?
        xml.LotRent listing.lot_rent&.to_f if listing.lot_rent.present?
        
        # Description
        xml.Description do
          xml.cdata! listing.description
        end
        
        # Features (Yes/No format)
        xml.Features do
          xml.Garage listing.has_garage? ? 'Yes' : 'No'
          xml.Fireplace listing.has_fireplace? ? 'Yes' : 'No'
          xml.Deck listing.has_deck? ? 'Yes' : 'No'
          xml.Shed listing.has_shed? ? 'Yes' : 'No'
          xml.Appliances listing.has_appliances? ? 'Yes' : 'No'
          xml.AC listing.has_ac? ? 'Yes' : 'No'
          xml.Furnished listing.is_furnished? ? 'Yes' : 'No'
          xml.PetsAllowed listing.pets_allowed? ? 'Yes' : 'No'
        end
        
        # Availability
        xml.FinancingAvailable listing.financing_available || 'Contact for details'
        xml.DeliveryAvailable listing.delivery_available || 'Yes'
        xml.SetupIncluded listing.setup_included || 'Contact for details'
        
        # Contact (uses Location → Company fallback)
        xml.Seller do
          xml.Name listing_seller_name(listing)
          xml.Phone format_phone(listing_contact_phone(listing))
          xml.Email listing_contact_email(listing)
        end
        
        # Metadata
        xml.Status listing.status
        xml.PublishedAt listing.published_at&.iso8601
        xml.UpdatedAt listing.updated_at.iso8601
        
        # Images
        if vehicle.images.present?
          xml.Images do
            vehicle.images.each_with_index do |image, index|
              image_url = image.is_a?(Hash) ? (image['url'] || image[:url]) : image
              next if image_url.blank?
              
              xml.Image do
                xml.URL image_url
                xml.Rank index + 1
              end
            end
          end
        end
      end
    end
    
    # Helper methods
    
    def company_email
      company_email_for(company)
    end
    
    def company_phone
      company_phone_for(company)
    end
    
    def company_email_for(comp)
      # Company doesn't have email - use first user or default
      comp.users.first&.email || 'info@example.com'
    end
    
    def company_phone_for(comp)
      # Company doesn't have phone - use first user or default
      comp.users.first&.phone || '123-456-7890'
    end
    
    def format_phone(phone)
      return '123-456-7890' if phone.blank?
      
      digits = phone.gsub(/\D/, '')
      
      if digits.length == 10
        "(#{digits[0..2]}) #{digits[3..5]}-#{digits[6..9]}"
      else
        phone
      end
    end
  end
end

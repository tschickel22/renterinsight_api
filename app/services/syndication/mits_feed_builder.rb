# frozen_string_literal: true

module Syndication
  class MitsFeedBuilder
    attr_reader :company, :partner, :listings
    
    def initialize(company:, partner:, listings:)
      @company = company
      @partner = partner
      @listings = listings
    end
    
    def build_xml
      require 'builder'
      
      xml = Builder::XmlMarkup.new(indent: 2)
      xml.instruct! :xml, version: '1.0', encoding: 'UTF-8'
      
      xml.PhysicalProperty do
        add_management_section(xml)
        add_properties(xml)
      end
      
      xml.target!
    end
    
    private
    
    def add_management_section(xml)
      xml.Management(IDValue: company_identifier) do
        xml.PropertyContacts do
          xml.Companies do
            xml.CompanyName company.name
            xml.WebSite company.custom_domain || company.subdomain_url || ''
            xml.Phone(PhoneType: 'office') do
              xml.PhoneNumber format_phone(company_phone)
            end
            xml.Email company_email
          end
        end
      end
    end
    
    def add_properties(xml)
      grouped_listings = listings.group_by(&:mits_property_id)
      
      grouped_listings.each do |property_id, property_listings|
        add_property(xml, property_id, property_listings)
      end
    end
    
    def add_property(xml, property_id, property_listings)
      first_listing = property_listings.first
      
      xml.Property(
        IDValue: property_id,
        OrganizationName: company.name,
        IDType: 'Company'
      ) do
        add_property_id(xml, first_listing)
        add_property_coordinates(xml, first_listing)
        add_property_information(xml, first_listing)
        add_property_amenities(xml, first_listing)
        add_property_pet_policy(xml, first_listing)
        add_units(xml, property_listings)
        add_property_photos(xml, first_listing)
        add_promotional(xml, first_listing)
      end
    end
    
    def add_property_id(xml, listing)
      xml.PropertyID do
        xml.Identification(IDValue: listing.mits_property_id, IDRank: 'primary')
        xml.Identification(
          IDValue: company_identifier,
          OrganizationName: company.name,
          IDType: 'Company'
        )
        xml.MarketingName listing.property_name || listing.display_name
        
        xml.Address(AddressType: 'property') do
          xml.AddressLine1 listing.vehicle.location_address || ''
          xml.City listing.vehicle.location_city || ''
          xml.State listing.vehicle.location_state || ''
          xml.PostalCode listing.vehicle.location_zip || ''
        end
        
        xml.Phone(PhoneType: 'office') do
          xml.PhoneNumber format_phone(listing.seller_phone || company_phone)
        end
        
        xml.Email listing.seller_email || company_email
      end
    end
    
    def add_property_coordinates(xml, listing)
      return unless listing.latitude.present? && listing.longitude.present?
      
      xml.ILS_Identification(
        ILS_IdentificationType: 'Apartment',
        RentalType: 'Unspecified'
      ) do
        xml.Latitude listing.latitude
        xml.Longitude listing.longitude
      end
    end
    
    def add_property_information(xml, listing)
      xml.Information do
        add_office_hours(xml, listing)
        
        xml.LongDescription do
          xml.cdata! listing.description
        end
        
        add_parking(xml, listing) if listing.formatted_parking.present?
      end
    end
    
    def add_office_hours(xml, listing)
      hours = listing.formatted_office_hours
      
      if hours.empty?
        # Default office hours
        %w[Monday Tuesday Wednesday Thursday Friday].each do |day|
          xml.OfficeHour do
            xml.OpenTime '9:00 AM'
            xml.CloseTime '5:00 PM'
            xml.Day day
          end
        end
        %w[Saturday Sunday].each do |day|
          xml.OfficeHour do
            xml.OpenTime 'Closed'
            xml.CloseTime 'Closed'
            xml.Day day
          end
        end
      else
        hours.each do |hour|
          xml.OfficeHour do
            xml.OpenTime hour['open_time'] || 'Closed'
            xml.CloseTime hour['close_time'] || 'Closed'
            xml.Day hour['day']
          end
        end
      end
    end
    
    def add_parking(xml, listing)
      parking = listing.formatted_parking
      
      xml.Parking(ParkingType: parking['type'] || 'Surface Lot') do
        xml.Assigned parking['assigned'] || false
        xml.AssignedFee parking['assigned_fee'] || 'Paid'
        xml.SpaceFee parking['space_fee'] || 0
        xml.Spaces parking['spaces'] || 0
        xml.Comment parking['comment'] || ''
      end
    end
    
    def add_property_amenities(xml, listing)
      return if listing.formatted_property_amenities.empty?
      
      listing.formatted_property_amenities.each do |amenity|
        xml.Amenity(AmenityType: amenity['type'] || 'Other') do
          xml.Description amenity['description']
        end
      end
    end
    
    def add_property_pet_policy(xml, listing)
      return if listing.formatted_pet_policy.empty?
      
      policy = listing.formatted_pet_policy
      
      xml.Policy do
        xml.Pet(Allowed: policy['allowed'] || listing.pets_allowed?) do
          if policy['cats_allowed']
            xml.Pets(PetType: 'Cat', Count: policy['cat_count'] || 2, Weight: policy['cat_weight'] || 99)
          end
          if policy['dogs_allowed']
            xml.Pets(PetType: 'Dog', Count: policy['dog_count'] || 2, Weight: policy['dog_weight'] || 99)
          end
          
          xml.Comment policy['comment'] || ''
          xml.Deposit policy['deposit'] || 0
          xml.Fee policy['fee'] || 0
          xml.Rent policy['rent'] || 0
          xml.Restrictions policy['restrictions'] || 'Contact office for pet policy details'
          xml.PetCare policy['pet_care'] || false
        end
      end
    end
    
    def add_units(xml, property_listings)
      property_listings.each do |listing|
        add_unit(xml, listing)
      end
    end
    
    def add_unit(xml, listing)
      xml.ILS_Unit(IDValue: listing.unit_number || listing.id) do
        xml.Units do
          xml.Unit do
            xml.MarketingName listing.unit_number || listing.display_name
            xml.MinSquareFeet listing.vehicle.square_feet || 500
            xml.MarketRent listing.rent_price.to_i
          end
        end
        
        add_concession(xml, listing)
        
        if listing.effective_rent.present?
          xml.EffectiveRent(
            Min: listing.effective_rent.to_i,
            Max: listing.rent_price.to_i
          )
        end
        
        add_availability(xml, listing)
        add_unit_amenities(xml, listing)
        add_promotional(xml, listing)
      end
    end
    
    def add_concession(xml, listing)
      return if listing.concessions.blank?
      
      xml.Concession(Active: 'TRUE') do
        xml.DescriptionBody listing.concessions
      end
    end
    
    def add_availability(xml, listing)
      return unless listing.available_date.present?
      
      xml.Availability do
        xml.MadeReadyDate(
          Month: listing.available_date.strftime('%m'),
          Day: listing.available_date.strftime('%d'),
          Year: listing.available_date.strftime('%Y')
        )
      end
    end
    
    def add_unit_amenities(xml, listing)
      return if listing.formatted_unit_amenities.empty?
      
      listing.formatted_unit_amenities.each do |amenity|
        xml.Amenity(AmenityType: amenity['type'] || 'Other') do
          xml.Description amenity['description']
        end
      end
    end
    
    def add_property_photos(xml, listing)
      # Placeholder for photo integration with ActiveStorage
      # In production, this would pull from listing.photos or vehicle.photos
      
      # Example structure:
      # xml.File(Active: 'true') do
      #   xml.FileType 'Photo'
      #   xml.Name 'property-photo.jpg'
      #   xml.Format 'image/jpeg'
      #   xml.Src 'https://cdn.example.com/photo.jpg'
      #   xml.Rank 1
      # end
    end
    
    def add_promotional(xml, listing)
      return if listing.promotional_text.blank?
      
      xml.Promotional listing.promotional_text
    end
    
    # Helper methods
    
    def company_identifier
      "company-#{company.id}"
    end
    
    def company_phone
      # Try to get from company settings or users
      company.users.first&.phone || '123-456-7890'
    end
    
    def company_email
      # Try to get from communications settings
      company.communications_settings&.dig('email_from') || 
        company.users.first&.email || 
        'info@example.com'
    end
    
    def format_phone(phone)
      return '123-456-7890' if phone.blank?
      
      # Remove non-numeric characters
      digits = phone.gsub(/\D/, '')
      
      # Format as XXX-XXX-XXXX
      if digits.length == 10
        "#{digits[0..2]}-#{digits[3..5]}-#{digits[6..9]}"
      else
        phone
      end
    end
  end
end

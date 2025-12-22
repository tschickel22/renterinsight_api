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
          xml.PhoneNumber format_phone(listing_contact_phone(listing))
        end
        
        xml.Email listing_contact_email(listing)
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
      xml.ILS_Unit(IDValue: listing.id) do
        xml.Units do
          xml.Unit do
            xml.MarketingName listing.display_name
            xml.MinSquareFeet listing.vehicle.square_feet || 500
            xml.MarketRent listing.rent_price.to_i
            
            # Unit details
            xml.UnitType listing.unit_type if listing.unit_type.present?
            xml.FloorPlanName listing.floor_plan_name if listing.floor_plan_name.present?
            xml.FloorNumber listing.floor_number if listing.floor_number.present?
            xml.Furnished listing.is_furnished? ? 'Yes' : 'No'
          end
        end
        
        # Deposits and fees
        add_deposits_and_fees(xml, listing)
        
        add_concession(xml, listing)
        
        if listing.effective_rent.present?
          xml.EffectiveRent(
            Min: listing.effective_rent.to_i,
            Max: listing.rent_price.to_i
          )
        end
        
        # Lease terms
        add_lease_terms(xml, listing)
        
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
    
    def add_deposits_and_fees(xml, listing)
      xml.Deposit do
        xml.Amount listing.security_deposit.to_i if listing.security_deposit.present?
        xml.PetDeposit listing.pet_deposit.to_i if listing.pet_deposit.present?
        xml.KeyDeposit listing.key_deposit.to_i if listing.key_deposit.present?
        xml.OtherDeposit listing.other_deposit.to_i if listing.other_deposit.present?
      end if listing.security_deposit.present? || listing.pet_deposit.present?
      
      # Monthly fees
      xml.Fee do
        xml.ApplicationFee listing.application_fee.to_i if listing.application_fee.present?
        xml.AdminFee listing.admin_fee.to_i if listing.admin_fee.present?
        xml.PetRent listing.pet_rent.to_i if listing.pet_rent.present?
        xml.ParkingFee listing.parking_fee.to_i if listing.parking_fee.present?
        xml.StorageFee listing.storage_fee.to_i if listing.storage_fee.present?
        xml.TrashFee listing.trash_fee.to_i if listing.trash_fee.present?
      end if listing.application_fee.present? || listing.admin_fee.present? || 
             listing.pet_rent.present? || listing.parking_fee.present?
    end
    
    def add_lease_terms(xml, listing)
      return unless listing.lease_terms.present? || listing.min_lease_term.present?
      
      xml.LeaseTerm do
        xml.MinimumMonths listing.min_lease_term if listing.min_lease_term.present?
        xml.MaximumMonths listing.max_lease_term if listing.max_lease_term.present?
        
        # Format lease type properly
        lease_type = listing.lease_type.presence || 'fixed'
        formatted_lease_type = case lease_type.downcase
                               when 'fixed' then 'Fixed'
                               when 'month_to_month' then 'month_to_month'
                               when 'both' then 'Both'
                               else lease_type.titleize
                               end
        xml.LeaseType formatted_lease_type
        
        xml.Terms listing.lease_terms if listing.lease_terms.present?
      end
    end
    
    def add_availability(xml, listing)
      return unless listing.available_date.present?
      
      # Parse date if it's a string
      date = listing.available_date.is_a?(String) ? Date.parse(listing.available_date) : listing.available_date
      
      xml.Availability do
        xml.MadeReadyDate(
          Month: date.strftime('%m'),
          Day: date.strftime('%d'),
          Year: date.strftime('%Y')
        )
      end
    rescue ArgumentError, TypeError
      # Skip if date is invalid
      nil
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
      vehicle = listing.vehicle
      return if vehicle.images.blank?
      
      vehicle.images.each_with_index do |image, index|
        # Handle both string URLs and hash objects
        image_url = image.is_a?(Hash) ? (image['url'] || image[:url]) : image
        next if image_url.blank?
        
        # Extract filename from URL
        filename = image_url.split('/').last || "photo-#{index + 1}.jpg"
        
        # Determine format from filename or default to jpeg
        format = case filename.downcase.split('.').last
                 when 'png' then 'image/png'
                 when 'gif' then 'image/gif'
                 when 'webp' then 'image/webp'
                 else 'image/jpeg'
                 end
        
        xml.File(Active: 'true') do
          xml.FileType 'Photo'
          xml.Name filename
          xml.Format format
          xml.Src image_url
          xml.Rank index + 1
        end
      end
    end
    
    def add_promotional(xml, listing)
      return if listing.promotional_text.blank?
      
      xml.Promotional listing.promotional_text
    end
    
    # Helper methods
    
    def listing_contact_email(listing)
      listing.contact_email.presence || company_email
    end
    
    def listing_contact_phone(listing)
      listing.contact_phone.presence || company_phone
    end
    
    def company_identifier
      "company-#{company.id}"
    end
    
    def company_phone
      # Company doesn't have phone - use first user or default
      company.users.first&.phone || '123-456-7890'
    end
    
    def company_email
      # Company doesn't have email - use first user or default
      company.users.first&.email || 'info@example.com'
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

# frozen_string_literal: true

module Agreements
  # The dealer's address and phone for an agreement's `company.address` and
  # `company.phone` merge fields: the agreement's location (Location Settings)
  # when it has them, else the company's (Company Settings). Same order as the
  # Dealer Logo. The address used to read `street` and `zip`, which are not
  # columns, so the street and ZIP never printed for any dealer.
  module DealerContact
    module_function

    def address(company, location_id: nil)
      location = location_for(company, location_id)
      source = [location, company].compact.find { |s| s.try(:address_line1).present? || s.try(:city).present? }
      format_address(source)
    end

    def phone(company, location_id: nil)
      location_for(company, location_id)&.try(:phone).presence || company&.try(:phone).presence
    end

    # The location an agreement prints for: its own, else its deal's.
    def location_id_for(agreement, deal: nil)
      deal ||= agreement.deal_id.present? ? agreement.company.deals.find_by(id: agreement.deal_id) : nil
      agreement.location_id.presence || deal&.try(:location_id)
    end

    def location_for(company, location_id)
      return nil if company.nil? || location_id.blank?

      company.locations.find_by(id: location_id)
    end

    # "3710 Highway 45 North, Columbus, MS 39705"
    def format_address(source)
      return nil unless source

      street = [source.try(:address_line1), source.try(:address_line2)].compact_blank.join(' ')
      state_zip = [source.try(:state), source.try(:zip_code)].compact_blank.join(' ')
      [street, source.try(:city), state_zip].compact_blank.join(', ').presence
    end
  end
end

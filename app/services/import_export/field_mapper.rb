# frozen_string_literal: true

module ImportExport
  # Suggests a CSV-header → model-field mapping using normalized + alias matching.
  class FieldMapper
    ALIASES = {
      'first_name'    => %w[firstname first fname given_name],
      'last_name'     => %w[lastname last lname surname family_name],
      'email'         => %w[email_address e_mail mail],
      'phone'         => %w[phone_number telephone tel mobile cell],
      'company_name'  => %w[company organization org account],
      'zip'           => %w[zipcode postal_code postcode],
      'street'        => %w[address address1 street_address],
      'vin'           => %w[vehicle_identification_number],
      'sku'           => %w[stock_keeping_unit item_code product_code],
      'stock_number'  => %w[stock stock_no],
      'ticket_number' => %w[ticket],
      'invoice_number'=> %w[invoice],
      'quote_number'  => %w[quote],
      # Lookup field aliases
      'account_name'      => %w[account accountname account_name company_account],
      'contact_email'     => %w[contactemail contact_email],
      'contact_name'      => %w[contactname contact_name contact],
      'owner_email'       => %w[owneremail owner_email assigned_to_email],
      'owner_name'        => %w[ownername owner assignedto assigned_to],
      'location_name'     => %w[locationname location_name location dealership],
      'source_name'       => %w[sourcename source_name leadsource lead_source source],
      'vehicle_stock'     => %w[vehiclestock vehicle_stock_number stock_number stockno stock_no],
      'vehicle_vin'       => %w[vehiclevin vehicle_vin],
      'salesperson_email' => %w[salesperson_email salesperson sales_rep sales_rep_email],
      'category_name'     => %w[categoryname category_name category],
      'deal_name'         => %w[dealname deal_name deal deal_number],
      'sales_rep_email'   => %w[salesrepemail sales_rep_email rep_email],
      'sales_rep_name'    => %w[salesrepname sales_rep_name salesrep rep],
    }.freeze

    def initialize(headers, fields)
      @headers = headers
      @fields  = fields
    end

    def call
      mapping = {}
      unmapped_headers = []

      @headers.each do |header|
        match = best_match(header)
        if match
          mapping[header] = match
        else
          unmapped_headers << header
        end
      end

      mapped_keys = mapping.values
      unmapped_fields = @fields.reject { |f| mapped_keys.include?(f[:key]) }

      { suggested_mapping: mapping, unmapped_headers: unmapped_headers, unmapped_fields: unmapped_fields }
    end

    private

    def best_match(header)
      norm = normalize(header)

      exact = @fields.find { |f| normalize(f[:key]) == norm || normalize(f[:label]) == norm }
      return exact[:key] if exact

      aliased = @fields.find do |f|
        aliases = ALIASES[f[:key]] || []
        aliases.any? { |a| normalize(a) == norm }
      end
      return aliased[:key] if aliased

      contains = @fields.find { |f| normalize(f[:key]).include?(norm) || norm.include?(normalize(f[:key])) }
      contains&.dig(:key)
    end

    def normalize(str)
      str.to_s.downcase.gsub(/[^a-z0-9]/, '')
    end
  end
end

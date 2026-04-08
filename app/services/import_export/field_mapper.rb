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
      'quote_number'  => %w[quote]
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

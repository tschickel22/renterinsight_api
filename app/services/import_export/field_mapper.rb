# frozen_string_literal: true

module ImportExport
  # Suggests a CSV-header → model-field mapping using normalized + alias matching.
  #
  # Matches are scored by confidence so that when two headers claim the same
  # field, the stronger claim wins and the weaker header is left UNMAPPED
  # rather than silently overwriting real data. (Importer#build_row_hash lets
  # the last non-blank column win, so an unchecked weak match like
  # "Email Follow Up" → email would clobber the actual "Email" column.)
  class FieldMapper
    ALIASES = {
      'first_name'    => %w[firstname first fname given_name],
      'last_name'     => %w[lastname last lname surname family_name],
      'email'         => %w[email_address e_mail mail],
      'phone'         => %w[phone_number telephone tel mobile cell],
      'company_name'  => %w[company organization org account account_name accountname],
      'title'         => %w[job_title jobtitle position],
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
      # Tag column — pipe- or comma-separated values resolved to Tag records.
      'tags'              => %w[tag tags label labels tag_names],
    }.freeze

    # Confidence tiers. Higher wins when two headers claim the same field.
    STRENGTH_EXACT   = 3 # header == field key or label
    STRENGTH_ALIAS   = 2 # header == a known alias
    STRENGTH_PARTIAL = 1 # field name appears as whole word(s) inside the header

    def initialize(headers, fields)
      @headers = headers
      @fields  = fields
    end

    def call
      # field_key => { header:, strength: } — only the best claim survives.
      claims = {}

      @headers.each do |header|
        key, strength = best_match(header)
        next unless key

        incumbent = claims[key]
        # Ties go to the first header, matching the previous first-wins order.
        next if incumbent && strength <= incumbent[:strength]

        claims[key] = { header: header, strength: strength }
      end

      winners = claims.each_with_object({}) { |(key, claim), h| h[claim[:header]] = key }

      # Rebuild in original header order; anything that lost a claim (or never
      # matched) is reported as unmapped so the UI can offer skip / map-to-existing
      # / create-custom-field for it.
      mapping          = {}
      unmapped_headers = []
      @headers.each do |header|
        if winners.key?(header)
          mapping[header] = winners[header]
        else
          unmapped_headers << header
        end
      end

      mapped_keys = mapping.values
      unmapped_fields = @fields.reject { |f| mapped_keys.include?(f[:key]) }

      { suggested_mapping: mapping, unmapped_headers: unmapped_headers, unmapped_fields: unmapped_fields }
    end

    private

    # Returns [field_key, strength] or nil.
    def best_match(header)
      norm = normalize(header)

      exact = @fields.find { |f| normalize(f[:key]) == norm || normalize(f[:label]) == norm }
      return [exact[:key], STRENGTH_EXACT] if exact

      aliased = @fields.find do |f|
        aliases = ALIASES[f[:key]] || []
        aliases.any? { |a| normalize(a) == norm }
      end
      return [aliased[:key], STRENGTH_ALIAS] if aliased

      # Word-boundary containment. Comparing on tokens (not raw substrings)
      # keeps "Zip/Postal Code" → zip and "Note" → notes working while it no
      # longer treats every "<field> <qualifier>" header as the field itself.
      header_tokens = tokenize(header)
      partial = @fields.find do |f|
        token_run?(header_tokens, tokenize(f[:key])) ||
          token_run?(header_tokens, tokenize(f[:label])) ||
          token_run?(tokenize(f[:key]), header_tokens)
      end
      partial ? [partial[:key], STRENGTH_PARTIAL] : nil
    end

    # True when `needle` appears as a contiguous run of whole words in `haystack`.
    def token_run?(haystack, needle)
      return false if needle.empty? || haystack.empty? || needle.length > haystack.length

      haystack.each_cons(needle.length).any? do |slice|
        slice.each_with_index.all? { |tok, i| token_match?(tok, needle[i]) }
      end
    end

    # Whole-word equality, tolerating simple singular/plural and short suffix
    # drift ("note"/"notes", "tag"/"tags") but not arbitrary prefixes.
    def token_match?(a, b)
      return true if a == b
      return false if a.length < 3 || b.length < 3
      return false if (a.length - b.length).abs > 2

      a.start_with?(b) || b.start_with?(a)
    end

    def tokenize(str)
      str.to_s.downcase.split(/[^a-z0-9]+/).reject(&:empty?)
    end

    def normalize(str)
      str.to_s.downcase.gsub(/[^a-z0-9]/, '')
    end
  end
end

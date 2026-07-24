# frozen_string_literal: true

module Integration
  # Single source of truth for the partner-API mappable fields per module. Used
  # by BOTH the partner controllers' strong params (what create/update accept)
  # AND the "Export field map" reference — so the exported list and the accepted
  # list can never drift. Every key here is a real, settable attribute (plus the
  # `source` name alias on leads, which is consumed before assignment). company_id
  # is deliberately never included.
  module MappableFields
    KEYS = {
      'leads' => %i[
        first_name last_name email phone status source source_id owner_id location_id
        company_name title
        co_applicant_first_name co_applicant_last_name co_applicant_email co_applicant_phone
        budget_range purchase_timeframe preferred_contact_method interests_requirements
        rv_experience vehicle_id
        preferred_bedrooms preferred_bathrooms preferred_min_sqft preferred_max_sqft preferred_home_type
        notes
      ],
      'contacts' => %i[
        first_name last_name email phone title department company_name account_id owner_id
        location_id is_primary
        street city state zip country
        delivery_street delivery_city delivery_state delivery_zip delivery_country
        opt_out_email opt_out_sms
        preferred_bedrooms preferred_bathrooms preferred_min_sqft preferred_max_sqft preferred_home_type
        budget_range preferred_vehicle_id deposit_amount notes
      ],
      'accounts' => %i[
        name status account_type email phone website industry rating ownership
        annual_revenue employee_count description notes account_number
        billing_street billing_city billing_state billing_postal_code billing_country
        shipping_street shipping_city shipping_state shipping_postal_code shipping_country
        owner_id location_id source_id parent_account_id deposit_amount
      ],
      'deals' => %i[
        name value stage probability expected_close_date actual_close_date description notes
        customer_name deal_type vertical quantity delivery_date
        account_id contact_id owner_id location_id vehicle_id source_id territory_id
        selling_price unit_cost trade_allowance trade_payoff
        doc_fee delivery_fee setup_fee skirting_fee accessories_total pack_amount
        finance_reserve product_margin
        billing_street billing_city billing_state billing_zip billing_country
        delivery_street delivery_city delivery_state delivery_zip delivery_country
      ]
    }.freeze

    # Aliases the API also understands, surfaced as a note in the export.
    NOTES = {
      'first_name' => 'or send full_name to auto-split into first/last',
      'email'      => 'or email_address',
      'phone'      => 'or phone_number',
      'source'     => 'source name — resolved/created automatically'
    }.freeze

    module_function

    def modules
      KEYS.keys
    end

    def supported?(module_name)
      KEYS.key?(module_name.to_s)
    end

    def keys(module_name)
      KEYS[module_name.to_s] || []
    end

    # [{ key:, label:, note: }] for the export.
    def field_map(module_name)
      keys(module_name).map do |k|
        { key: k.to_s, label: k.to_s.titleize, note: NOTES[k.to_s] }
      end
    end
  end
end

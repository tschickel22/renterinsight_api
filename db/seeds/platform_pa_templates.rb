# Platform Purchase Agreement Templates
# These are standard Form 500 templates from Jenkins Business Forms
# Each state has a unique variant (Form EV500WV for WV, etc.)
#
# Usage: bin/rails runner "load 'db/seeds/platform_pa_templates.rb'"
#
# These are PLATFORM-level templates (company_id is nil for truly platform-level,
# but since company_id has NOT NULL constraint, we use a dedicated platform company)
# For now, we'll make them available to ALL companies via is_platform_template flag.

puts "Seeding Platform PA Templates..."

# ============================================================
# SHARED FIELD DEFINITIONS
# The Form 500 page 1 is very similar across states.
# We define the common fields here, then state-specific overrides below.
# ============================================================

FORM_500_PAGE1_FIELDS = [
  # ---- GROUP: buyer (Buyer Information) ----
  { key: 'buyer_names', label: 'Buyer(s)', type: 'text', group: 'buyer', page: 1, required: true, filled_by: 'preparer', position: 1, merge_from: 'contact.full_name', placeholder: 'Full name(s) of buyer(s)' },
  { key: 'buyer_address', label: 'Address', type: 'text', group: 'buyer', page: 1, required: true, filled_by: 'preparer', position: 2, merge_from: 'contact.street' },
  { key: 'buyer_city', label: 'City', type: 'text', group: 'buyer', page: 1, required: true, filled_by: 'preparer', position: 3, merge_from: 'contact.city' },
  { key: 'buyer_state', label: 'State', type: 'text', group: 'buyer', page: 1, required: true, filled_by: 'preparer', position: 4, merge_from: 'contact.state' },
  { key: 'buyer_zip', label: 'ZIP', type: 'text', group: 'buyer', page: 1, required: true, filled_by: 'preparer', position: 5, merge_from: 'contact.zip' },
  { key: 'buyer_home_phone', label: 'Home Phone', type: 'text', group: 'buyer', page: 1, filled_by: 'preparer', position: 6, merge_from: 'contact.phone' },
  { key: 'buyer_cell_phone', label: 'Cell Phone', type: 'text', group: 'buyer', page: 1, filled_by: 'preparer', position: 7, merge_from: 'contact.mobile_phone' },
  { key: 'buyer_email', label: 'Email', type: 'text', group: 'buyer', page: 1, filled_by: 'preparer', position: 8, merge_from: 'contact.email' },
  { key: 'agreement_date', label: 'Date', type: 'date', group: 'buyer', page: 1, required: true, filled_by: 'preparer', position: 9 },
  { key: 'sales_person', label: 'Sales Person', type: 'text', group: 'buyer', page: 1, filled_by: 'preparer', position: 10, merge_from: 'deal.owner_name' },

  # ---- GROUP: delivery (Delivery Address) ----
  { key: 'delivery_address', label: 'Delivery Address', type: 'text', group: 'delivery', page: 1, filled_by: 'preparer', position: 1 },
  { key: 'delivery_city', label: 'City', type: 'text', group: 'delivery', page: 1, filled_by: 'preparer', position: 2 },
  { key: 'delivery_state', label: 'State', type: 'text', group: 'delivery', page: 1, filled_by: 'preparer', position: 3 },
  { key: 'delivery_zip', label: 'ZIP', type: 'text', group: 'delivery', page: 1, filled_by: 'preparer', position: 4 },

  # ---- GROUP: unit (Unit Description) ----
  { key: 'unit_new_used', label: 'New/Used', type: 'select', group: 'unit', page: 1, required: true, filled_by: 'preparer', position: 1, options: ['New', 'Used'], merge_from: 'vehicle.condition' },
  { key: 'unit_single_double', label: 'Single/Double Wide', type: 'select', group: 'unit', page: 1, required: true, filled_by: 'preparer', position: 2, options: ['Single Wide', 'Double Wide'], merge_from: 'vehicle.sections' },
  { key: 'unit_make', label: 'Make', type: 'text', group: 'unit', page: 1, required: true, filled_by: 'preparer', position: 3, merge_from: 'vehicle.make' },
  { key: 'unit_model', label: 'Model', type: 'text', group: 'unit', page: 1, required: true, filled_by: 'preparer', position: 4, merge_from: 'vehicle.model' },
  { key: 'unit_stock_number', label: 'Stock Number', type: 'text', group: 'unit', page: 1, filled_by: 'preparer', position: 5, merge_from: 'vehicle.stock_number' },
  { key: 'unit_serial_number', label: 'Serial Number', type: 'text', group: 'unit', page: 1, filled_by: 'preparer', position: 6, merge_from: 'vehicle.vin' },
  { key: 'unit_year', label: 'Year', type: 'text', group: 'unit', page: 1, required: true, filled_by: 'preparer', position: 7, merge_from: 'vehicle.year' },
  { key: 'unit_bedrooms', label: 'Bedrooms', type: 'number', group: 'unit', page: 1, filled_by: 'preparer', position: 8, merge_from: 'vehicle.bedrooms' },
  { key: 'unit_baths', label: 'Baths', type: 'number', group: 'unit', page: 1, filled_by: 'preparer', position: 9, merge_from: 'vehicle.bathrooms' },
  { key: 'unit_floor_length', label: 'Floor Size L', type: 'number', group: 'unit', page: 1, filled_by: 'preparer', position: 10, merge_from: 'vehicle.length' },
  { key: 'unit_floor_width', label: 'Floor Size W', type: 'number', group: 'unit', page: 1, filled_by: 'preparer', position: 11, merge_from: 'vehicle.width' },
  { key: 'unit_hitch_size_l', label: 'Hitch Size L', type: 'text', group: 'unit', page: 1, filled_by: 'preparer', position: 12 },
  { key: 'unit_hitch_size_w', label: 'Hitch Size W', type: 'text', group: 'unit', page: 1, filled_by: 'preparer', position: 13 },
  { key: 'unit_color', label: 'Color', type: 'text', group: 'unit', page: 1, filled_by: 'preparer', position: 14, merge_from: 'vehicle.exterior_color' },
  { key: 'unit_key_numbers', label: 'Key Numbers', type: 'text', group: 'unit', page: 1, filled_by: 'preparer', position: 15 },
  { key: 'proposed_delivery_date', label: 'Proposed Delivery Date', type: 'date', group: 'unit', page: 1, filled_by: 'preparer', position: 16 },

  # ---- GROUP: insulation (Insulation Information) ----
  { key: 'insulation_ceiling_rvalue', label: 'Ceiling R-Value', type: 'number', group: 'insulation', page: 1, filled_by: 'preparer', position: 1 },
  { key: 'insulation_ceiling_thickness', label: 'Ceiling Thickness', type: 'text', group: 'insulation', page: 1, filled_by: 'preparer', position: 2 },
  { key: 'insulation_ceiling_type', label: 'Ceiling Type', type: 'text', group: 'insulation', page: 1, filled_by: 'preparer', position: 3 },
  { key: 'insulation_exterior_rvalue', label: 'Exterior R-Value', type: 'number', group: 'insulation', page: 1, filled_by: 'preparer', position: 4 },
  { key: 'insulation_exterior_thickness', label: 'Exterior Thickness', type: 'text', group: 'insulation', page: 1, filled_by: 'preparer', position: 5 },
  { key: 'insulation_exterior_type', label: 'Exterior Type', type: 'text', group: 'insulation', page: 1, filled_by: 'preparer', position: 6 },
  { key: 'insulation_floors_rvalue', label: 'Floors R-Value', type: 'number', group: 'insulation', page: 1, filled_by: 'preparer', position: 7 },
  { key: 'insulation_floors_thickness', label: 'Floors Thickness', type: 'text', group: 'insulation', page: 1, filled_by: 'preparer', position: 8 },
  { key: 'insulation_floors_type', label: 'Floors Type', type: 'text', group: 'insulation', page: 1, filled_by: 'preparer', position: 9 },

  # ---- GROUP: pricing (Financial Summary) ----
  { key: 'base_price', label: 'Base Price of Unit', type: 'currency', group: 'pricing', page: 1, required: true, filled_by: 'preparer', position: 1, format_as: 'currency' },
  { key: 'optional_equipment_total', label: 'Optional Equipment', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 2, format_as: 'currency', placeholder: 'Auto-calculated from deal line items' },
  { key: 'sub_total_1', label: 'Sub-Total', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 3, format_as: 'currency', formula: '=base_price + optional_equipment_total' },
  { key: 'sales_tax', label: 'Sales Tax', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 4, format_as: 'currency' },
  { key: 'nontaxable_items', label: 'Nontaxable Items', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 5, format_as: 'currency' },
  { key: 'various_fees', label: 'Various Fees and Insurance', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 6, format_as: 'currency' },
  { key: 'cash_purchase_price', label: 'Cash Purchase Price', type: 'currency', group: 'pricing', page: 1, required: true, filled_by: 'preparer', position: 7, format_as: 'currency', formula: '=sub_total_1 + sales_tax' },
  { key: 'trade_in_allowance', label: 'Trade-In Allowance', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 8, format_as: 'currency' },
  { key: 'less_balance_due', label: 'Less Bal. Due on Above', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 9, format_as: 'currency' },
  { key: 'net_allowance', label: 'Net Allowance', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 10, format_as: 'currency', formula: '=trade_in_allowance - less_balance_due' },
  { key: 'cash_down_payment', label: 'Cash Down Payment', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 11, format_as: 'currency' },
  { key: 'cash_as_agreed', label: 'Cash As Agreed', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 12, format_as: 'currency' },
  { key: 'less_total_credits', label: 'Less Total Credits', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 13, format_as: 'currency', formula: '=net_allowance + cash_down_payment + cash_as_agreed' },
  { key: 'sub_total_2', label: 'Sub-Total', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 14, format_as: 'currency', formula: '=cash_purchase_price - less_total_credits' },
  { key: 'sales_tax_additional', label: 'Sales Tax (If Not Included Above)', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 15, format_as: 'currency' },
  { key: 'unpaid_balance', label: 'Unpaid Balance of Cash Sale Price', type: 'currency', group: 'pricing', page: 1, required: true, filled_by: 'preparer', position: 16, format_as: 'currency', formula: '=sub_total_2 + sales_tax_additional' },

  # ---- GROUP: optional_equipment (Optional Equipment Line Items) ----
  # These are dynamic — populated from deal line items at agreement creation time.
  # The preparer can also add/edit manually. Each is a description + amount pair.
  # We define a starting amount field here; the actual line items come from optional_equipment_snapshot.
  { key: 'optional_equipment_start_amount', label: 'Optional Equipment Starting Amount', type: 'currency', group: 'optional_equipment', page: 1, filled_by: 'preparer', position: 1, format_as: 'currency', placeholder: 'First line item amount' },
  { key: 'balance_carried_to_optional', label: 'Balance Carried to Optional Equipment', type: 'currency', group: 'optional_equipment', page: 1, filled_by: 'preparer', position: 99, format_as: 'currency' },

  # ---- GROUP: remarks ----
  { key: 'remarks', label: 'Remarks', type: 'text', group: 'remarks', page: 1, filled_by: 'preparer', position: 1, placeholder: 'Payment schedule, special terms, etc.' },
  { key: 'attachments_text', label: 'Attachments', type: 'text', group: 'remarks', page: 1, filled_by: 'preparer', position: 2, placeholder: 'List of attached documents' },

  # ---- GROUP: trade_in (Trade-In Description) ----
  { key: 'trade_description', label: 'Description of Trade In', type: 'text', group: 'trade_in', page: 1, filled_by: 'preparer', position: 1 },
  { key: 'trade_make', label: 'Make', type: 'text', group: 'trade_in', page: 1, filled_by: 'preparer', position: 2 },
  { key: 'trade_model', label: 'Model', type: 'text', group: 'trade_in', page: 1, filled_by: 'preparer', position: 3 },
  { key: 'trade_year', label: 'Year', type: 'text', group: 'trade_in', page: 1, filled_by: 'preparer', position: 4 },
  { key: 'trade_color', label: 'Color', type: 'text', group: 'trade_in', page: 1, filled_by: 'preparer', position: 5 },
  { key: 'trade_bedrooms', label: 'Bedrooms', type: 'text', group: 'trade_in', page: 1, filled_by: 'preparer', position: 6 },
  { key: 'trade_size', label: 'Size', type: 'text', group: 'trade_in', page: 1, filled_by: 'preparer', position: 7 },
  { key: 'trade_title_no', label: 'Title No.', type: 'text', group: 'trade_in', page: 1, filled_by: 'preparer', position: 8 },
  { key: 'trade_serial_no', label: 'Serial No.', type: 'text', group: 'trade_in', page: 1, filled_by: 'preparer', position: 9 },
  { key: 'trade_amount_owing', label: 'Amount Owing', type: 'currency', group: 'trade_in', page: 1, filled_by: 'preparer', position: 10, format_as: 'currency' },
  { key: 'trade_to_whom', label: 'To Whom', type: 'text', group: 'trade_in', page: 1, filled_by: 'preparer', position: 11 },
  { key: 'trade_debt_paid_by', label: 'Debt Paid By', type: 'select', group: 'trade_in', page: 1, filled_by: 'preparer', position: 12, options: ['Dealer', 'Buyer'] },
].freeze

# Page 2 of Form 500 is Additional Terms and Conditions — mostly static boilerplate.
# Only the buyer name appears at top and signatures at bottom.
FORM_500_PAGE2_FIELDS = [
  { key: 'page2_buyer_names', label: 'Buyer Names (Page 2)', type: 'text', group: 'terms', page: 2, filled_by: 'preparer', position: 1, merge_from: 'contact.full_name' },
].freeze

# ============================================================
# SEED HELPER
# ============================================================

def seed_platform_template(attrs)
  # Platform templates need a company_id due to NOT NULL constraint.
  # We use company_id of the FIRST company as a workaround.
  # The is_platform_template flag makes them available to ALL companies.
  # In production, you'd have a dedicated "Platform" company or remove the constraint.
  platform_company = Company.first

  unless platform_company
    puts "  ⚠️  No companies found — cannot seed platform templates. Create a company first."
    return nil
  end

  template = AgreementTemplate.find_or_initialize_by(
    form_number: attrs[:form_number],
    is_platform_template: true
  )

  template.assign_attributes(
    company_id: platform_company.id,
    name: attrs[:name],
    description: attrs[:description],
    template_type: 'upload',
    status: 'active',
    form_type: attrs[:form_type],
    form_number: attrs[:form_number],
    state_code: attrs[:state_code],
    is_platform_template: true,
    is_system_template: true,
    page_count: attrs[:page_count],
    custom_field_definitions: attrs[:custom_field_definitions],
    # No document_url or field_placements yet — needs clean PDF upload
    document_url: nil,
    field_placements: [],
    merge_field_placements: [],
    default_signers: attrs[:default_signers] || [],
    is_deleted: false
  )

  if template.save
    action = template.previously_new_record? ? 'Created' : 'Updated'
    puts "  ✅ #{action}: #{template.name} (#{template.form_number}, #{template.state_code})"
  else
    puts "  ❌ Failed: #{attrs[:name]} — #{template.errors.full_messages.join(', ')}"
  end

  template
end

# ============================================================
# INDIANA — Form 500 (Jenkins Form EV500IN or FDHC PA)
# 16-page Purchase Agreement used by Factory Direct Homes Center
# ============================================================

indiana_extra_fields = [
  # Indiana PA has a Preferred Payment Discount section (page varies)
  { key: 'preferred_payment_discount', label: 'Preferred Payment Discount', type: 'currency', group: 'pricing', page: 1, filled_by: 'preparer', position: 20, format_as: 'currency' },
  { key: 'multi_unit_discount_pct', label: 'Multi-Unit Discount %', type: 'percentage', group: 'pricing', page: 1, filled_by: 'preparer', position: 21, format_as: 'percentage' },

  # Indiana has a Shipping Directions & Map page (page 14 in the 16-page version)
  { key: 'shipping_address_1', label: 'Shipping Address Line 1', type: 'text', group: 'shipping', page: 14, filled_by: 'preparer', position: 1 },
  { key: 'shipping_address_2', label: 'Shipping Address Line 2', type: 'text', group: 'shipping', page: 14, filled_by: 'preparer', position: 2 },
  { key: 'shipping_address_3', label: 'Shipping Address Line 3', type: 'text', group: 'shipping', page: 14, filled_by: 'preparer', position: 3 },
  { key: 'shipping_address_4', label: 'Shipping Address Line 4', type: 'text', group: 'shipping', page: 14, filled_by: 'preparer', position: 4 },
  { key: 'shipping_contact_name', label: 'Contact Name', type: 'text', group: 'shipping', page: 14, filled_by: 'preparer', position: 5 },
  { key: 'shipping_daytime_phone', label: 'Daytime Phone', type: 'text', group: 'shipping', page: 14, filled_by: 'preparer', position: 6 },
  { key: 'shipping_evening_phone', label: 'Evening Phone', type: 'text', group: 'shipping', page: 14, filled_by: 'preparer', position: 7 },
  { key: 'shipping_mobile_phone', label: 'Mobile Phone', type: 'text', group: 'shipping', page: 14, filled_by: 'preparer', position: 8 },
  { key: 'shipping_directions', label: 'Directions', type: 'text', group: 'shipping', page: 14, filled_by: 'preparer', position: 9 },
]

indiana_default_signers = [
  { role: 'signer', order_index: 0, label: 'Dealer Representative' },
  { role: 'signer', order_index: 1, label: 'Dealer Manager' },
  { role: 'signer', order_index: 2, label: 'Buyer 1' },
  { role: 'signer', order_index: 3, label: 'Buyer 2' },
]

seed_platform_template(
  name: 'Purchase Agreement — Indiana (FDHC PA)',
  description: 'Factory Direct Homes Center Purchase Agreement for Indiana. 16-page form including unit description, pricing, optional equipment, insulation disclosure, trade-in, shipping directions, and terms & conditions. Signatures required on multiple pages.',
  form_type: 'purchase_agreement',
  form_number: 'FDHC_PA_IN',
  state_code: 'IN',
  page_count: 16,
  custom_field_definitions: FORM_500_PAGE1_FIELDS + FORM_500_PAGE2_FIELDS + indiana_extra_fields,
  default_signers: indiana_default_signers
)

# ============================================================
# WEST VIRGINIA — Form EV500WV
# 2-page Purchase Agreement (standard Jenkins Business Forms Form 500)
# ============================================================

wv_extra_fields = [
  # WV-specific: controlling law references WV state law (section 12 of terms)
  # No extra data fields beyond standard Form 500 — terms are printed on Page 2
]

wv_default_signers = [
  { role: 'signer', order_index: 0, label: 'Dealer (Approved By)' },
  { role: 'signer', order_index: 1, label: 'Buyer 1' },
  { role: 'signer', order_index: 2, label: 'Buyer 2' },
]

seed_platform_template(
  name: 'Purchase Agreement — West Virginia (Form EV500WV)',
  description: 'Standard Jenkins Business Forms Form 500 for West Virginia. 2-page purchase agreement with unit description, pricing, optional equipment, trade-in section, and terms & conditions on page 2.',
  form_type: 'purchase_agreement',
  form_number: 'EV500WV',
  state_code: 'WV',
  page_count: 2,
  custom_field_definitions: FORM_500_PAGE1_FIELDS + FORM_500_PAGE2_FIELDS + wv_extra_fields,
  default_signers: wv_default_signers
)

# ============================================================
# SUMMARY
# ============================================================

total = AgreementTemplate.where(is_platform_template: true).count
puts ""
puts "Platform PA Templates: #{total} total"
AgreementTemplate.where(is_platform_template: true).order(:state_code).each do |t|
  field_count = t.custom_field_definitions&.length || 0
  groups = (t.custom_field_definitions || []).map { |f| f['group'] }.uniq.compact
  puts "  #{t.state_code} — #{t.name} (#{field_count} fields in #{groups.length} groups: #{groups.join(', ')})"
end

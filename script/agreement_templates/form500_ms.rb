# frozen_string_literal: true

# Builds the Mississippi Form 500 purchase agreement (3 pages: agreement,
# additional terms, arbitration addendum) as a PLATFORM template, offered to
# every company whose forms resolve to MS.
#
#   bin/rails runner script/agreement_templates/form500_ms.rb RI-00014 --expect "DealerTide"
#   bin/rails runner script/agreement_templates/form500_ms.rb RI-00014 --expect "DealerTide" --apply
#
# Preview is the default and changes nothing. --apply uploads the PDF and
# creates the template (or rebuilds it in place on a re-run, so agreements
# already made from it keep their link). The account is the platform tenant
# that owns the PDF's storage folder; --expect guards against the wrong one,
# because account numbers come from company ids and differ per environment.
#
# The PDF beside this file was made from a filled-out dealer copy: every
# flattened value, the dealer header and logo, the DRAFT marks and the
# publisher footer were removed, leaving the blank form. Each field below sits
# on the rectangle the original form's own field occupied (points, converted
# to percent of a 612 x 792 page).

account = ARGV[0] or abort 'usage: bin/rails runner script/agreement_templates/form500_ms.rb <account_number> --expect "<name>" [--apply]'
expect  = ARGV[ARGV.index('--expect') + 1] if ARGV.include?('--expect')
apply   = ARGV.include?('--apply')
abort 'Pass --expect "<part of the company name>" so the template cannot land on the wrong tenant.' if expect.blank?

company = Company.find_by(account_number: account) or abort "No company with account number #{account}."
unless company.name.downcase.include?(expect.downcase)
  abort "#{account} is \"#{company.name}\" (id #{company.id}), which does not match \"#{expect}\". Nothing changed."
end

PDF_PATH    = File.expand_path('form500_ms.pdf', __dir__)
FORM_NUMBER = 'FORM500_MS'
NAME        = 'Form 500 Purchase Agreement - MS'

BUYER_1 = 0
BUYER_2 = 1
DEALER  = 2
DEFAULT_SIGNERS = [
  { role: 'signer', order_index: 0, label: 'Buyer 1' },
  { role: 'signer', order_index: 1, label: 'Buyer 2' },
  { role: 'signer', order_index: 2, label: 'Dealer (Approved By)' }
].freeze

PAGE_W = 612.0
PAGE_H = 792.0

@definitions = {}
@placements  = []

# Coordinates are PDF points from the top-left corner: x, y, width, height.
def place(page, key, label, type, x, y, w, h, extra = {})
  @placements << {
    'id' => "ms500_#{@placements.size + 1}",
    'fieldKey' => key, 'fieldLabel' => label, 'fieldType' => type,
    'page' => page - 1,
    'x' => (x / PAGE_W * 100).round(2), 'y' => (y / PAGE_H * 100).round(2),
    'width' => (w / PAGE_W * 100).round(2), 'height' => (h / PAGE_H * 100).round(2)
  }.merge(extra)
end

# A field the rep fills (or that fills itself from the deal) in the builder.
def field(page, key, label, x, y, w, h = 11.7, type: 'text', group: 'general', merge_from: nil, formula: nil, options: nil, options_from: nil)
  @definitions[key] ||= {
    'key' => key, 'label' => label, 'type' => type, 'group' => group, 'page' => page,
    'required' => false, 'position' => @definitions.size + 1, 'filled_by' => 'preparer'
  }.tap do |d|
    d['merge_from'] = merge_from if merge_from
    d['formula'] = formula if formula
    d['options'] = options if options
    d['options_from'] = options_from if options_from
    d['format_as'] = 'currency' if type == 'currency'
  end
  place(page, "custom.#{key}", label, type, x, y, w, h, 'isCustomField' => true, 'isSignerField' => false)
end

# A value we already hold: placed as the merge field itself.
def merge(page, key, label, x, y, w, h = 11.7, type: 'text')
  place(page, key, label, type, x, y, w, h, 'isCustomField' => false, 'isSignerField' => false)
end

def signer(page, who, type, x, y, w, h, label)
  place(page, "signer.#{type}", label, type, x, y, w, h, 'isCustomField' => false, 'isSignerField' => true, 'signerIndex' => who)
end

# The header space the form leaves open: the dealer's logo on the left
# (Location branding, else Company branding), name, address and phone beside it.
def dealer_header(page, top, logo_h)
  merge page, 'company.logo', 'Dealer logo', 24, top, 230, logo_h, type: 'image'
  merge page, 'company.name', 'Dealer name', 262, top, 230, 15
  merge page, 'company.address', 'Dealer address', 262, top + 15, 230, 12
  merge page, 'company.phone', 'Dealer phone', 262, top + 27, 230, 12
end

# ── Page 1: Purchase Agreement ────────────────────────────────────────────
dealer_header 1, 12, 58

field 1, 'buyer_names', 'Buyer(s)', 20.4, 80.2, 337.0, group: 'buyer', merge_from: 'deal.buyer_names'
merge 1, 'contact.phone', 'Home phone', 359.2, 80.2, 81.2
merge 1, 'contact.mobile_phone', 'Cell phone', 441.6, 80.2, 80.1
merge 1, 'date.today', 'Date', 524.1, 80.2, 67.2, type: 'date'
merge 1, 'contact.street', 'Address', 20.4, 101.3, 249.4
merge 1, 'contact.city', 'City', 271.5, 101.5, 95.8
merge 1, 'contact.state', 'State', 369.2, 101.5, 28.5
merge 1, 'contact.zip', 'ZIP', 398.9, 101.5, 33.9
merge 1, 'contact.email', 'Email', 434.1, 101.5, 157.2
merge 1, 'deal.delivery_street', 'Delivery address', 20.4, 122.6, 269.4
merge 1, 'deal.delivery_city', 'Delivery city', 291.4, 122.7, 95.8
merge 1, 'deal.delivery_state', 'Delivery state', 388.6, 122.7, 28.5
merge 1, 'deal.delivery_zip', 'Delivery ZIP', 418.2, 122.7, 33.9
merge 1, 'deal.owner_name', 'Sales person', 453.6, 122.7, 137.8

field 1, 'unit_new', 'New', 50, 137, 11, 9.5, type: 'checkbox', group: 'unit', merge_from: 'vehicle.is_new'
field 1, 'unit_used', 'Used', 50, 147.5, 11, 9.5, type: 'checkbox', group: 'unit', merge_from: 'vehicle.is_used'
field 1, 'unit_single_wide', 'Single wide', 92, 137, 11, 9.5, type: 'checkbox', group: 'unit', merge_from: 'vehicle.is_single_section'
field 1, 'unit_double_wide', 'Double wide', 92, 147.5, 11, 9.5, type: 'checkbox', group: 'unit', merge_from: 'vehicle.is_multi_section'
merge 1, 'vehicle.make', 'Make', 167.4, 145.6, 119.0
merge 1, 'vehicle.model', 'Model', 288.5, 145.8, 111.0
merge 1, 'vehicle.stock_number', 'Stock number', 401.4, 145.8, 71.5
merge 1, 'vehicle.serial_number', 'Serial number', 474.7, 145.8, 116.7
merge 1, 'vehicle.year', 'Year', 20.4, 170.0, 31.9
merge 1, 'vehicle.bedrooms', 'Bedrooms', 55.1, 170.2, 45.5
merge 1, 'vehicle.length', 'Floor size L', 109, 170.2, 45.2
merge 1, 'vehicle.width', 'Floor size W', 165, 170.2, 43.7
# We hold no hitch size, so it starts as the floor size and the dealer corrects it.
field 1, 'hitch_size_l', 'Hitch size L', 216, 170.2, 29.5, group: 'unit', merge_from: 'vehicle.length'
field 1, 'hitch_size_w', 'Hitch size W', 255, 170.2, 27.7, group: 'unit', merge_from: 'vehicle.width'
merge 1, 'vehicle.exterior_color', 'Color', 284.4, 170.2, 119.0
field 1, 'key_numbers', 'Key numbers', 405.0, 170.2, 91.0, group: 'unit'
field 1, 'proposed_delivery_date', 'Proposed delivery date', 497.9, 170.2, 93.4, type: 'date', group: 'unit', merge_from: 'deal.delivery_date'

# Insulation disclosure (FTC 16 CFR 460.16)
[['ceiling', 196.4, 'vehicle.insulation_r_roof'], ['exterior', 208.2, 'vehicle.insulation_r_wall'],
 ['floors', 219.8, 'vehicle.insulation_r_floor']].each do |loc, y, r_from|
  name = loc.capitalize
  field 1, "insulation_#{loc}_r_value", "#{name} R-value", 109.8, y, 55.0, 10.2, group: 'insulation', merge_from: r_from
  field 1, "insulation_#{loc}_thickness", "#{name} thickness", 166.7, y, 59.4, 10.2, group: 'insulation'
  field 1, "insulation_#{loc}_type", "#{name} insulation type", 228.1, y, 110.7, 10.2, group: 'insulation', merge_from: 'vehicle.insulation_type'
end

# Price column. Lines fill from the deal and stay editable; subtotals, cash
# price, credits and the unpaid balance are formulas so the column adds up.
def price(key, label, y, x: 526.9, w: 64.5, **opts)
  field 1, key, label, x, y, w, 10.7, type: 'currency', group: 'pricing', **opts
end

def charge_line(n, y)
  field 1, "other_charge_#{n}_label", "Other charge #{n} (description)", 345.3, y, 173.6, 10.7, group: 'pricing'
  price "other_charge_#{n}", "Other charge #{n}", y
end

price 'base_price', 'Base price of unit', 183.8, merge_from: 'deal.selling_price'
price 'optional_equipment', 'Optional equipment', 195.6, formula: '=balance_carried'
charge_line 1, 207.3
price 'sub_total_1', 'Sub-total', 219.1, formula: '=base_price + optional_equipment + other_charge_1'
charge_line 2, 231.6
price 'sales_tax', 'Sales tax', 243.7, merge_from: 'deal.tax_amount'
charge_line 3, 255.6
price 'non_taxable_items', 'Non-taxable items', 267.4
price 'various_fees', 'Various fees and insurance', 279.7, merge_from: 'deal.fee_total'
price 'cash_purchase_price', 'Cash purchase price', 291.4,
      formula: '=sub_total_1 + other_charge_2 + sales_tax + other_charge_3 + non_taxable_items + various_fees'
price 'trade_in_allowance', 'Trade-in allowance', 303.7, x: 460.0, w: 58.9, merge_from: 'deal.trade_allowance'
price 'less_balance_due', 'Less bal. due on trade', 315.5, x: 460.0, w: 58.9, merge_from: 'deal.trade_payoff'
price 'net_allowance', 'Net allowance', 327.6, x: 460.0, w: 58.9, formula: '=trade_in_allowance - less_balance_due'
price 'cash_down_payment', 'Cash down payment', 339.7, x: 460.0, w: 58.9, merge_from: 'deal.contract_down_payment'
price 'cash_as_agreed', 'Cash as agreed', 351.7, x: 460.0, w: 58.9, merge_from: 'deal.additional_payment'
price 'less_total_credits', 'Less total credits', 363.4, formula: '=net_allowance + cash_down_payment + cash_as_agreed'
price 'sub_total_2', 'Sub-total after credits', 375.7, formula: '=cash_purchase_price - less_total_credits'
price 'sales_tax_not_included', 'Sales tax (if not included above)', 387.7
price 'unpaid_balance', 'Unpaid balance of cash sale price', 399.4, formula: '=sub_total_2 + sales_tax_not_included'

field 1, 'remarks', 'Remarks', 343.1, 421.0, 248.2, 62.0, group: 'remarks'

# Optional equipment, labor and accessories: 22 ruled rows, filled from every
# deal line except the home (base price above) and fees (various fees above);
# the balance carried is their total.
OPTION_ROWS = [279.7, 291.8, 303.7, 315.5, 327.4, 339.7, 351.8, 363.6, 375.6, 387.7, 399.8,
               411.7, 423.8, 435.8, 447.9, 459.8, 471.4, 483.7, 495.5, 507.4, 519.6, 531.3].freeze
OPTION_ROWS.each_with_index do |y, i|
  merge 1, "deal.line_items_options[#{i}].description", "Optional equipment #{i + 1}", 20.4, y, 255.0, 10.7
  merge 1, "deal.line_items_options[#{i}].line_total", "Optional equipment #{i + 1} amount", 283.6, y, 55.2, 10.7, type: 'currency'
end
field 1, 'balance_carried', 'Balance carried to optional equipment', 283.6, 543.4, 55.2, 10.7,
      type: 'currency', group: 'optional_equipment', formula: '=sum(deal.line_items_options.line_total)'

# Trade-in
field 1, 'trade_description', 'Trade-in description', 20.4, 564.6, 209.0, 10.7, group: 'trade_in'
field 1, 'trade_make', 'Trade-in make', 230.7, 564.6, 158.3, 10.7, group: 'trade_in'
field 1, 'trade_model', 'Trade-in model', 390.3, 564.6, 157.3, 10.7, group: 'trade_in'
field 1, 'trade_year', 'Trade-in year', 549.6, 564.6, 41.8, 10.7, group: 'trade_in'
field 1, 'trade_color', 'Trade-in color', 20.4, 585.3, 151.2, 10.7, group: 'trade_in'
field 1, 'trade_bedrooms', 'Trade-in bedrooms', 173.1, 585.3, 38.7, 10.7, group: 'trade_in'
field 1, 'trade_size_l', 'Trade-in size L', 213.1, 585.3, 31.8, 10.7, group: 'trade_in'
field 1, 'trade_size_w', 'Trade-in size W', 247.7, 585.3, 31.8, 10.7, group: 'trade_in'
field 1, 'trade_title_no', 'Trade-in title no.', 280.8, 585.3, 153.5, 10.7, group: 'trade_in'
field 1, 'trade_serial_no', 'Trade-in serial no.', 435.9, 585.3, 155.4, 10.7, group: 'trade_in'
field 1, 'trade_amount_owing', 'Amount owing on trade', 47.6, 599.7, 44.5, 10.7, type: 'currency', group: 'trade_in', merge_from: 'deal.trade_payoff'
field 1, 'trade_owed_to', 'Trade debt owed to', 115.8, 599.7, 192.5, 10.7, group: 'trade_in'
field 1, 'trade_debt_paid_by_dealer', 'Trade debt paid by Dealer', 497, 600, 10, 9.5, type: 'checkbox', group: 'trade_in'
field 1, 'trade_debt_paid_by_buyer', 'Trade debt paid by Buyer', 546, 600, 10, 9.5, type: 'checkbox', group: 'trade_in'

# Signatures: dealer name on the dealer line, the approving officer signs below.
merge 1, 'company.name', 'Dealer name', 24.6, 716.7, 259.2, 14.3
signer 1, BUYER_1, 'signature', 360, 717, 205, 14, 'Buyer 1 signature'
signer 1, BUYER_2, 'signature', 360, 743, 205, 18, 'Buyer 2 signature'
signer 1, DEALER, 'signature', 72, 743, 215, 18, 'Dealer approval signature'

# ── Page 2: Additional Terms and Conditions ───────────────────────────────
field 2, 'buyer_names', 'Buyer(s)', 203.0, 11.8, 337.0, group: 'buyer', merge_from: 'deal.buyer_names'

# ── Page 3: Arbitration Addendum ──────────────────────────────────────────
dealer_header 3, 42, 72
field 3, 'buyer_names', 'Buyer(s)', 20.6, 143.0, 337.0, group: 'buyer', merge_from: 'deal.buyer_names'
merge 3, 'contact.phone', 'Home phone', 359.7, 143.0, 81.2
merge 3, 'contact.mobile_phone', 'Cell phone', 443.4, 143.0, 80.1
merge 3, 'date.today', 'Date sold', 526.6, 143.0, 64.8, type: 'date'
merge 3, 'contact.street', 'Address', 20.6, 167.6, 249.4
merge 3, 'contact.city', 'City', 272.6, 167.6, 94.8
merge 3, 'contact.state', 'State', 369.5, 167.6, 25.4
merge 3, 'contact.zip', 'ZIP', 396.6, 167.6, 33.9
merge 3, 'contact.email', 'Email', 433.6, 167.6, 157.7
merge 3, 'company.name', 'Dealer name', 23.2, 450.7, 290.3, 14.3
signer 3, BUYER_1, 'signature', 385, 451, 170, 18, 'Buyer 1 arbitration signature'
signer 3, BUYER_2, 'signature', 385, 492, 170, 18, 'Buyer 2 arbitration signature'
signer 3, DEALER, 'signature', 45, 492, 280, 18, 'Dealer approval (arbitration)'

# ── Build ─────────────────────────────────────────────────────────────────
pages = @placements.group_by { |p| p['page'] + 1 }.transform_values(&:size).sort.map { |pg, n| "p#{pg}:#{n}" }.join(' ')
per_signer = @placements.select { |p| p['isSignerField'] }.group_by { |p| p['signerIndex'] }.transform_values(&:size)
existing = AgreementTemplate.find_by(form_number: FORM_NUMBER, is_platform_template: true, is_deleted: false)

puts apply ? 'APPLYING' : 'PREVIEW: nothing will be changed (add --apply to create it)'
puts "Storage owner: #{company.name} (id #{company.id}, #{company.account_number})"
puts "#{existing ? "Rebuild platform template ##{existing.id}" : 'Create platform template'} \"#{NAME}\": " \
     "#{@placements.size} fields, #{@definitions.size} fillable, 3 pages"
puts "  by page: #{pages}"
puts "  signer fields: " + DEFAULT_SIGNERS.map { |s| "#{s[:label]} #{per_signer[s[:order_index]].to_i}" }.join(', ')
exit unless apply

key = "agreements/#{company.id}/documents/form500_ms.pdf"
document = PrivateFiles.put(File.binread(PDF_PATH), key: key, content_type: 'application/pdf')

template = existing || AgreementTemplate.new(company_id: company.id, form_number: FORM_NUMBER)
template.assign_attributes(
  name: NAME,
  description: 'Mississippi Form 500 plain language purchase agreement: unit, insulation disclosure, price ' \
               'column, optional equipment, trade-in, additional terms (MS keeps implied warranties) and a ' \
               'binding arbitration addendum. Buyer, home and prices fill from the deal; subtotals, cash price ' \
               'and unpaid balance calculate.',
  template_type: 'upload',
  status: 'active',
  form_type: 'purchase_agreement',
  state_code: 'MS',
  page_count: 3,
  document_url: document,
  document_urls: [],
  custom_field_definitions: @definitions.values,
  merge_field_placements: @placements,
  field_placements: [],
  default_signers: DEFAULT_SIGNERS.map(&:stringify_keys),
  is_platform_template: true,
  is_system_template: true,
  is_deleted: false
)
template.save!
puts "Saved platform template ##{template.id} (status #{template.status}). PDF at #{document}"

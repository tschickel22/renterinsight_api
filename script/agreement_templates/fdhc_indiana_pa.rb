# frozen_string_literal: true

# Builds Factory Direct Homes Center's 16-page Indiana purchase agreement
# (their "PA-02-26" form) as a ready-to-use agreement template.
#
#   bin/rails runner script/agreement_templates/fdhc_indiana_pa.rb RI-00004 --expect "Factory Direct"
#   bin/rails runner script/agreement_templates/fdhc_indiana_pa.rb RI-00004 --expect "Factory Direct" --apply
#
# Preview is the default and changes nothing. --apply uploads the PDF and
# creates the template (or rebuilds it in place on a re-run, so agreements
# already made from it keep their link). --expect must match the company
# name: account numbers come from company ids, which differ per environment.
#
# Why this is a script and not a scan: the dealer's fillable PDF has 347
# native fields that Acrobat auto-named from nearby text ("fill_75",
# "Sub Total 2Buyer understands that..."), so the scanner cannot tell what
# they are, and it puts the dealer rep and Buyer 1 on the same signer. Every
# field below is placed from the PDF's own field rectangles or its printed
# labels. The PDF next to this file is their form re-rendered flat (pdftocairo),
# so the signing page does not show 347 empty editable boxes under ours.

account = ARGV[0] or abort 'usage: bin/rails runner script/agreement_templates/fdhc_indiana_pa.rb <account_number> --expect "<name>" [--apply]'
expect  = ARGV[ARGV.index('--expect') + 1] if ARGV.include?('--expect')
apply   = ARGV.include?('--apply')
abort 'Pass --expect "<part of the company name>" so the template cannot land on the wrong tenant.' if expect.blank?

company = Company.find_by(account_number: account) or abort "No company with account number #{account}."
unless company.name.downcase.include?(expect.downcase)
  abort "#{account} is \"#{company.name}\" (id #{company.id}), which does not match \"#{expect}\". Nothing changed."
end

PDF_PATH    = File.expand_path('fdhc_indiana_pa_02_26.pdf', __dir__)
FORM_NUMBER = 'FDHC_IN_PA_0226'
NAME        = 'Factory Direct Purchase Agreement (Indiana)'

# Signers, in the order the builder offers them. A deal with one buyer picks
# "3 signers" and only Buyer 2 drops; fields for a missing signer stay blank.
BUYER_1 = 0
REP     = 1
MANAGER = 2
BUYER_2 = 3
DEFAULT_SIGNERS = [
  { role: 'signer', order_index: 0, label: 'Buyer 1' },
  { role: 'signer', order_index: 1, label: 'Dealer Representative' },
  { role: 'signer', order_index: 2, label: 'Dealer Manager' },
  { role: 'signer', order_index: 3, label: 'Buyer 2' }
].freeze

@definitions = {}
@placements  = []

def place(page, key, label, type, x, y, w, h, extra = {})
  @placements << {
    'id' => "fdhc_#{@placements.size + 1}",
    'fieldKey' => key, 'fieldLabel' => label, 'fieldType' => type,
    'page' => page - 1, 'x' => x.round(2), 'y' => y.round(2), 'width' => w.round(2), 'height' => h.round(2)
  }.merge(extra)
end

# A field the rep fills (or that fills itself from the deal) in the builder.
# The same key may be placed on several pages; it is defined once.
def field(page, key, label, x, y, w, h = 1.6, type: 'text', group: 'general', merge_from: nil, formula: nil, options: nil)
  @definitions[key] ||= {
    'key' => key, 'label' => label, 'type' => type, 'group' => group, 'page' => page,
    'required' => false, 'position' => @definitions.size + 1, 'filled_by' => 'preparer'
  }.tap do |d|
    d['merge_from'] = merge_from if merge_from
    d['formula'] = formula if formula
    d['options'] = options if options
    d['format_as'] = 'currency' if type == 'currency'
  end
  place(page, "custom.#{key}", label, type, x, y, w, h, 'isCustomField' => true, 'isSignerField' => false)
end

def signer(page, who, type, x, y, w, h, label)
  place(page, "signer.#{type}", label, type, x, y, w, h, 'isCustomField' => false, 'isSignerField' => true, 'signerIndex' => who)
end

def initials_pair(page, y, x1, x2, w = 4.5, h = 1.5)
  signer(page, BUYER_1, 'initials', x1, y, w, h, 'Buyer 1 initials')
  signer(page, BUYER_2, 'initials', x2, y, w, h, 'Buyer 2 initials')
end

# The form's native signature rectangles are often under 1% tall. Grow each
# one upward from its baseline so a drawn signature has room.
def sig_box(x, y, w, h, min_h = 2.4)
  bottom = y + h
  h = [h, min_h].max
  [x, bottom - h, w, h]
end

# Rep, manager, both buyers and both buyers' dates: the block at the foot of
# most pages. Each argument is the native [x, y, w, h].
def signature_block(page, rep:, mgr:, b1:, b2:, d1:, d2:)
  signer(page, REP,     'signature',   *sig_box(*rep), 'Dealer Representative signature')
  signer(page, MANAGER, 'signature',   *sig_box(*mgr), 'Dealer Manager signature')
  signer(page, BUYER_1, 'signature',   *sig_box(*b1),  'Buyer 1 signature')
  signer(page, BUYER_2, 'signature',   *sig_box(*b2),  'Buyer 2 signature')
  signer(page, BUYER_1, 'date_signed', *sig_box(*d1, 1.8), 'Buyer 1 date')
  signer(page, BUYER_2, 'date_signed', *sig_box(*d2, 1.8), 'Buyer 2 date')
end

REP_BOX = [8.18, 82.16, 33.63, 2.73].freeze
MGR_BOX = [8.93, 87.37, 33.63, 1.58].freeze
def standard_block(page, b1_y, b2_y, h)
  signature_block(page, rep: REP_BOX, mgr: MGR_BOX,
                        b1: [50.8, b1_y, 29.12, h], b2: [50.8, b2_y, 29.12, h],
                        d1: [81.31, b1_y, 11.18, h], d2: [81.31, b2_y, 11.18, h])
end

# ── Page 1: Purchase Agreement ────────────────────────────────────────────
field 1, 'buyer_1_name', 'Buyer 1', 10.78, 8.38, 24.24, 1.73, group: 'buyer', merge_from: 'contact.full_name'
field 1, 'buyer_2_name', 'Buyer 2', 38.76, 8.38, 24.25, 1.73, group: 'buyer'
field 1, 'agreement_date', 'Date', 65.47, 8.38, 10.27, 1.73, group: 'buyer', merge_from: 'date.today'
field 1, 'deal_number', 'Deal #', 80.49, 8.38, 12.04, 1.73, group: 'buyer', merge_from: 'deal.deal_number'
field 1, 'mailing_address', 'Mailing Address', 11.2, 10.35, 28.22, 1.82, group: 'buyer', merge_from: 'contact.street'
field 1, 'mailing_city', 'Mailing City', 41.61, 10.35, 15.27, 1.82, group: 'buyer', merge_from: 'contact.city'
field 1, 'mailing_state', 'Mailing State', 59.73, 10.35, 3.29, 1.82, group: 'buyer', merge_from: 'contact.state'
field 1, 'mailing_zip', 'Mailing ZIP', 64.67, 10.35, 11.08, 1.82, group: 'buyer', merge_from: 'contact.zip'
field 1, 'phone', 'Phone', 78.9, 10.35, 13.63, 1.82, group: 'buyer', merge_from: 'contact.phone'
field 1, 'delivery_address', 'Delivery Address', 11.27, 12.41, 28.14, 1.82, group: 'delivery', merge_from: 'deal.delivery_street'
field 1, 'delivery_city', 'Delivery City', 41.61, 12.41, 15.27, 1.82, group: 'delivery', merge_from: 'deal.delivery_city'
field 1, 'delivery_state', 'Delivery State', 59.73, 12.41, 3.29, 1.82, group: 'delivery', merge_from: 'deal.delivery_state'
field 1, 'delivery_zip', 'Delivery ZIP', 64.67, 12.41, 11.08, 1.82, group: 'delivery', merge_from: 'deal.delivery_zip'
field 1, 'cell', 'Cell', 78.08, 12.41, 14.45, 1.82, group: 'buyer', merge_from: 'contact.mobile_phone'
field 1, 'salesperson', 'Salesperson', 13.22, 14.45, 21.8, 1.73, group: 'buyer', merge_from: 'deal.owner_name'
field 1, 'email_1', 'Email Address 1', 41.73, 14.45, 22.22, 1.73, group: 'buyer', merge_from: 'contact.email'
field 1, 'email_2', 'Email Address 2', 70.61, 14.45, 21.92, 1.73, group: 'buyer'
field 1, 'home_make', 'Make', 13.35, 16.42, 10.0, 1.82, group: 'unit', merge_from: 'vehicle.make'
field 1, 'home_model', 'Model', 23.6, 16.42, 26.3, 1.82, group: 'unit', merge_from: 'vehicle.model'
field 1, 'home_year', 'Year', 52.45, 16.42, 8.25, 1.82, group: 'unit', merge_from: 'vehicle.year'
field 1, 'bedrooms', 'Bedrooms', 65.57, 16.42, 5.78, 1.82, group: 'unit', merge_from: 'vehicle.bedrooms'
field 1, 'baths', 'Baths', 74.29, 16.42, 7.82, 1.82, group: 'unit', merge_from: 'vehicle.bathrooms'
field 1, 'den', 'Den', 84.14, 16.42, 8.39, 1.82, group: 'unit'
field 1, 'serial_number', 'Serial Number', 13.78, 18.48, 19.49, 1.82, group: 'unit', merge_from: 'vehicle.serial_number'
field 1, 'new_used', 'New / Used', 38.31, 18.48, 11.63, 1.82, group: 'unit', merge_from: 'vehicle.condition'
field 1, 'floor_size', 'Floor Size', 54.94, 18.48, 8.08, 1.82, group: 'unit', merge_from: 'vehicle.floor_size'
field 1, 'hitch_size', 'Hitch Size', 69.0, 18.48, 10.0, 1.82, group: 'unit'
field 1, 'approx_sq_ft', 'Approx. Sq. Ft.', 82.84, 18.48, 9.69, 1.82, group: 'unit', merge_from: 'vehicle.square_feet'

# Price schedule. Lines fill from the deal and stay editable; the subtotals,
# total and unpaid balance are formulas, so the column always adds up.
PRICE_X = 77.6
PRICE_W = 14.9
# y is each printed label's top; the box sits 0.25 above it so text centers on the row.
def price(key, label, label_y, **opts)
  field 1, key, label, PRICE_X, label_y - 0.25, PRICE_W, 1.45, type: 'currency', group: 'pricing', **opts
end

# The unlabeled rows between charges; each gets a description and an amount.
OTHER_CHARGE_ROWS = [40.05, 41.7, 44.95, 49.8, 51.42, 53.08].freeze
def other_charge(n, row_y)
  field 1, "other_charge_#{n}_label", "Other charge #{n} (description)", 50.6, row_y - 0.25, 25.6, 1.45, group: 'pricing'
  price "other_charge_#{n}", "Other charge #{n}", row_y
end

price 'retail_price', 'Retail Price', 20.63, merge_from: 'deal.selling_price'
price 'factory_direct_savings', 'Factory Direct Savings', 22.24, merge_from: 'deal.dealer_discount'
price 'sub_total_1', 'Sub Total 1', 23.85, formula: '=retail_price - factory_direct_savings'
price 'addendum_a_upgrades', 'Addendum "A" Upgrades', 27.07, merge_from: 'deal.accessory_total_from_lines'
price 'sales_event_savings', 'Sales Event Savings', 28.57, merge_from: 'deal.sales_event_discount'
price 'manager_discount', 'Manager Discount', 30.4, merge_from: 'deal.manager_discount'
price 'preferred_payment_discount', 'Preferred Payment Discount (3%)', 32.1, merge_from: 'deal.preferred_payment_discount'
field 1, 'multi_unit_pct', 'Multi-Unit Discount %', 68.4, 33.34, 2.0, 1.45, type: 'number', group: 'pricing'
price 'multi_unit_discount', 'Multi-Unit Discount', 33.59, merge_from: 'deal.multi_unit_discount'
price 'sub_total_2', 'Sub Total 2', 35.21,
      formula: '=sub_total_1 + addendum_a_upgrades - sales_event_savings - manager_discount - preferred_payment_discount - multi_unit_discount'
price 'freight', 'Standard Freight Charge', 38.43
price 'setup_charges', 'Setup Charges', 43.35
price 'extended_service', 'Extended Service Agreement', 46.57
price 'document_fee', 'Document Fee', 48.18
OTHER_CHARGE_ROWS.each_with_index { |y, i| other_charge(i + 1, y) }
price 'taxes', 'Taxes', 54.71, merge_from: 'deal.tax_amount'
price 'total', 'Total', 57.93,
      formula: '=sub_total_2 + freight + setup_charges + extended_service + document_fee + taxes + ' +
               (1..6).map { |n| "other_charge_#{n}" }.join(' + ')
price 'down_payment', 'Down Payment', 59.53, merge_from: 'deal.down_payment'
price 'additional_payment', 'Additional Payment as Agreed', 61.14, merge_from: 'deal.additional_payment'
price 'unpaid_balance', 'Unpaid Balance', 62.75, formula: '=total - down_payment - additional_payment'

field 1, 'completion_month', 'Approximate completion month', 19.94, 36.91, 17.48, 1.89, group: 'terms'
field 1, 'notations_remarks', 'Notations & Remarks', 7.73, 57.83, 42.1, 6.2, group: 'remarks'
field 1, 'balance_due_by', 'Unpaid balance due on or before', 49.9, 67.64, 14.55, 1.14, group: 'terms'
field 1, 'additional_terms', 'Additional terms (shaded box)', 7.57, 69.09, 84.88, 3.44, group: 'remarks'

initials_pair 1, 26.35, 23.6, 30.25                  # construction & final payment
initials_pair 1, 44.95, 38.76, 44.05, 4.1, 1.3       # storage
initials_pair 1, 53.5, 16.4, 21.68, 4.1, 1.3         # freight
initials_pair 1, 64.15, 74.95, 80.93, 4.5, 1.3       # no verbal promises
initials_pair 1, 65.72, 67.58, 73.23, 4.5, 1.3       # certified funds
initials_pair 1, 67.22, 66.88, 73.14, 4.5, 1.3       # unpaid balance date
initials_pair 1, 75.95, 52.15, 59.03, 5.78, 1.2      # price increase
signature_block 1, rep: [8.18, 83.89, 33.63, 0.91], mgr: [8.18, 88.29, 33.63, 0.82],
                   b1: [50.8, 83.82, 29.12, 0.98], b2: [50.8, 88.12, 29.12, 0.98],
                   d1: [81.31, 83.82, 11.18, 0.98], d2: [81.31, 88.12, 11.18, 0.98]

# ── Page 2: Addendum "A" (upgrades), 39 rows from the deal's accessory lines ─
field 2, 'buyer_1_name', 'Buyer 1', 20.2, 6.0, 42.5, 1.8
field 2, 'home_model', 'Model', 71.2, 6.0, 20.3, 1.8
ADDENDUM_ROW_TOPS = [8.32, 10.18, 12.09, 13.95, 15.82, 17.64, 19.5, 21.36, 23.27, 25.14, 26.91, 28.82, 30.68,
                     32.55, 34.36, 36.23, 38.09, 39.98, 41.86, 43.64, 45.52, 47.41, 49.27, 51.07, 52.95, 54.82,
                     56.68, 58.59, 60.36, 62.23, 64.14, 66.0, 67.77, 69.68, 71.55, 73.41, 75.32, 77.09, 78.95, 80.91].freeze
ADDENDUM_ROW_TOPS.each_cons(2).with_index do |(top, bottom), i|
  h = bottom - top - 0.3
  place 2, "deal.line_items_accessory[#{i}].description", "Addendum A line #{i + 1}", 'text', 8.6, top + 0.15, 66.9, h,
        'isCustomField' => false, 'isSignerField' => false
  place 2, "deal.line_items_accessory[#{i}].line_total", "Addendum A line #{i + 1} amount", 'currency', 76.0, top + 0.15, 15.3, h,
        'isCustomField' => false, 'isSignerField' => false
end
field 2, 'addendum_a_upgrades', 'Addendum "A" Upgrades', 80.6, 81.3, 10.8, 1.8, type: 'currency', group: 'pricing'
initials_pair 2, 85.3, 9.4, 19.6, 8.5, 2.2
signer 2, BUYER_1, 'date_signed', 35.0, 85.3, 16.5, 2.2, 'Buyer 1 date'

# ── Page 3: Appliance and Electrical Work Sheet ───────────────────────────
APPLIANCE_ROWS = [
  ['appl_dishwasher_door_option', "Dishwasher door option", 17.30],
  ['appl_fireplace', "Fireplace", 19.00],
  ['appl_furnace_type', "Furnace type", 20.70],
  ['appl_furnace', "Furnace", 22.40],
  ['appl_dryer_hookup_type', "Dryer hookup type", 24.10],
  ['appl_dryer_hookup', "Dryer hookup", 25.80],
  ['appl_dryer', "Dryer", 27.50],
  ['appl_washer', "Washer", 29.20],
  ['appl_garbage_disposal_ready', "Garbage disposal ready", 30.89],
  ['appl_microwave_above_stove', "Microwave above stove", 32.59],
  ['appl_microwave_ready', "Microwave ready", 34.29],
  ['appl_garbage_disposal', "Garbage disposal", 35.99],
  ['appl_dishwasher_ready', "Dishwasher ready", 37.69],
  ['appl_dishwasher', "Dishwasher", 39.39],
  ['appl_ice_maker', "Ice maker", 41.09],
  ['appl_ice_maker_plumbing_only', "Ice maker plumbing only", 42.79],
  ['appl_heat_pump_ready', "Heat pump ready", 44.49],
  ['appl_freezer_plug', "Freezer plug", 46.19],
  ['appl_water_heater', "Water heater", 47.89],
  ['appl_water_heater_size', "Water heater size", 49.59],
  ['appl_ductwork', "Ductwork", 51.29],
  ['appl_range_hookup_type', "Range hookup type", 52.99],
  ['appl_range_hookup', "Range hookup", 54.68],
  ['appl_range_type', "Range type", 56.38],
  ['appl_range', "Range", 58.08],
  ['appl_appliance_color', "Appliance color", 59.78],
  ['appl_refrigerator_size', "Refrigerator size", 61.48],
  ['appl_refrigerator', "Refrigerator", 63.18],
  ['appl_ac_ready', "AC Ready", 64.88],
  ['appl_gas_service_on_home_site_to_be', "Gas service on home site to be", 66.58],
  ['appl_amperage', "Amperage", 68.28]
].freeze
field 3, 'buyer_1_name', 'Buyer 1', 28.94, 12.2, 61.24, 2.38
APPLIANCE_ROWS.each { |key, label, y| field 3, key, label, 52.1, y, 37.88, 1.7, group: 'appliances' }
signature_block 3, rep: [8.5, 80.2, 33.0, 2.38], mgr: [8.5, 84.6, 33.0, 2.38],
                   b1: [49.84, 80.2, 29.1, 2.38], b2: [49.84, 84.48, 29.1, 2.38],
                   d1: [80.35, 80.2, 11.18, 2.38], d2: [80.35, 84.48, 11.18, 2.38]

# ── Page 4: Color Selections (placed against the printed labels) ──────────
COLOR_ROWS = [
  ['color_interior_type', "Interior - Type", 12.80, 16.39, 36.70],
  ['color_interior_color', "Interior - Color", 13.10, 17.64, 36.40],
  ['color_interior_trim_color', "Interior Trim - Color", 13.10, 21.75, 36.40],
  ['color_interior_door_color', "Interior Door - Color", 13.10, 25.24, 36.40],
  ['color_accent_wall_color', "Accent Wall - Color", 13.10, 28.81, 36.40],
  ['color_accent_wall_location', "Accent Wall - Location", 15.04, 30.07, 34.46],
  ['color_tray_or_coffer_color', "Tray or Coffer - Color", 55.21, 21.75, 36.79],
  ['color_wainscot_color', "Wainscot - Color", 55.21, 25.24, 36.79],
  ['color_kitchen_sink_type', "Kitchen Sink - Type", 54.90, 28.81, 37.10],
  ['color_kitchen_sink_color', "Kitchen Sink - Color", 55.21, 30.07, 36.79],
  ['color_counter_tops_kitchen', "Counter Tops - Kitchen", 14.42, 34.18, 21.88],
  ['color_counter_tops_master_bath_color', "Counter Tops - Master Bath Color", 20.97, 35.43, 15.33],
  ['color_counter_tops_guest_bath', "Counter Tops - Guest Bath", 16.73, 36.68, 19.57],
  ['color_counter_tops_3rd_bath', "Counter Tops - 3rd Bath", 15.04, 37.93, 21.26],
  ['color_counter_tops_utility_room', "Counter Tops - Utility Room", 17.27, 39.18, 19.03],
  ['color_backsplash_kitchen', "Backsplash - Kitchen", 42.60, 34.18, 21.60],
  ['color_backsplash_master_bath', "Backsplash - Master Bath", 45.45, 35.43, 18.75],
  ['color_backsplash_guest_bath', "Backsplash - Guest Bath", 44.92, 36.68, 19.28],
  ['color_backsplash_3rd_bath', "Backsplash - 3rd Bath", 43.22, 37.93, 20.98],
  ['color_backsplash_utility_room', "Backsplash - Utility Room", 45.45, 39.18, 18.75],
  ['color_ceramic_edge_kitchen', "Ceramic Edge - Kitchen", 70.18, 34.18, 21.82],
  ['color_ceramic_edge_master_bath', "Ceramic Edge - Master Bath", 73.03, 35.43, 18.97],
  ['color_ceramic_edge_guest_bath', "Ceramic Edge - Guest Bath", 72.50, 36.68, 19.50],
  ['color_ceramic_edge_3rd_bath', "Ceramic Edge - 3rd Bath", 70.80, 37.93, 21.20],
  ['color_ceramic_edge_utility_room', "Ceramic Edge - Utility Room", 73.03, 39.18, 18.97],
  ['color_mosaic_insert_kitchen', "Mosaic Insert - Kitchen", 14.42, 43.21, 21.88],
  ['color_mosaic_insert_master_bath', "Mosaic Insert - Master Bath", 17.27, 44.46, 19.03],
  ['color_mosaic_insert_guest_bath', "Mosaic Insert - Guest Bath", 16.73, 45.71, 19.57],
  ['color_mosaic_insert_3rd_bath', "Mosaic Insert - 3rd Bath", 15.04, 46.96, 21.26],
  ['color_mosaic_insert_utility_room', "Mosaic Insert - Utility Room", 17.27, 48.21, 19.03],
  ['color_cabinet_type', "Cabinet - Type", 40.58, 43.21, 23.42],
  ['color_cabinet_style', "Cabinet - Style", 40.65, 44.46, 23.35],
  ['color_cabinet_hardware', "Cabinet - Hardware", 43.59, 45.71, 20.41],
  ['color_cabinet_hardware_color', "Cabinet - Hardware Color", 47.29, 46.96, 16.71],
  ['color_cabinet_color_kitchen', "Cabinet Color - Kitchen", 69.98, 43.21, 22.02],
  ['color_cabinet_color_master_bath', "Cabinet Color - Master Bath", 72.83, 44.46, 19.17],
  ['color_cabinet_color_guest_bath', "Cabinet Color - Guest Bath", 72.29, 45.71, 19.71],
  ['color_cabinet_color_3rd_bath', "Cabinet Color - 3rd Bath", 70.60, 46.96, 21.40],
  ['color_cabinet_color_utility_room', "Cabinet Color - Utility Room", 72.83, 48.21, 19.17],
  ['color_floor_carpet', "Floor - Carpet", 13.95, 52.24, 36.05],
  ['color_floor_carpet_color', "Floor - Carpet Color", 17.66, 53.49, 32.34],
  ['color_floor_linoleum', "Floor - Linoleum", 15.42, 54.74, 34.58],
  ['color_floor_linoleum_color', "Floor - Linoleum Color", 19.12, 55.99, 30.88],
  ['color_floor_wood_laminate', "Floor - Wood Laminate", 19.48, 57.24, 30.52],
  ['color_floor_wood_laminate_color', "Floor - Wood Laminate Color", 23.19, 58.49, 26.81],
  ['color_floor_ceramic_tile', "Floor - Ceramic Tile", 17.50, 59.75, 32.50],
  ['color_floor_ceramic_tile_color', "Floor - Ceramic Tile Color", 21.20, 61.00, 28.80],
  ['color_exterior_body', "Exterior - Body", 54.62, 52.24, 37.38],
  ['color_exterior_body_color', "Exterior - Body Color", 58.32, 53.49, 33.68],
  ['color_exterior_shingles', "Exterior - Shingles", 56.78, 54.74, 35.22],
  ['color_exterior_shingles_color', "Exterior - Shingles Color", 60.49, 55.99, 31.51],
  ['color_exterior_trim_color', "Exterior - Trim Color", 57.88, 57.24, 34.12],
  ['color_exterior_facia_soffit_color', "Exterior - Facia/Soffit Color", 62.08, 58.49, 29.92],
  ['color_exterior_accent_color', "Exterior - Accent Color", 59.40, 59.75, 32.60],
  ['color_exterior_shutter_color', "Exterior - Shutter Color", 59.64, 61.00, 32.36],
  ['color_exterior_roof_load', "Exterior - Roof Load", 57.86, 62.25, 34.14],
  ['color_decor_color', "Decor - Color", 13.10, 66.36, 36.90],
  ['color_interior_trim', "Interior Trim", 21.97, 19.45, 27.53],
  ['color_interior_door', "Interior Door", 22.41, 23.02, 27.09],
  ['color_accent_wall', "Accent Wall", 21.56, 26.51, 27.94],
  ['color_tray_or_coffer', "Tray or Coffer", 65.52, 19.45, 26.48],
  ['color_wainscot', "Wainscot", 61.21, 23.02, 30.79],
  ['color_kitchen_sink', "Kitchen Sink", 64.52, 26.51, 27.48],
  ['color_decor', "Decor", 15.95, 64.06, 33.55]
].freeze
field 4, 'buyer_1_name', 'Buyer 1', 29.04, 11.15, 61.22, 2.23
COLOR_ROWS.each { |key, label, x, y, w| field 4, key, label, x, y, w, 1.35, group: 'colors' }
field 4, 'color_notes', 'Color notes', 8.62, 69.73, 83.14, 9.01, group: 'colors'
signature_block 4, rep: REP_BOX, mgr: MGR_BOX,
                   b1: [50.8, 82.57, 29.12, 2.23], b2: [51.02, 87.12, 29.12, 2.07],
                   d1: [81.31, 82.74, 11.18, 2.07], d2: [81.31, 87.37, 11.18, 1.65]

# ── Page 5: Factory Direct Sale & Non-Installation Disclosure ─────────────
[20.41, 25.35, 29.89, 37.09, 40.58, 46.02, 48.55, 53.08, 57.5, 64.65, 69.18].each do |y|
  initials_pair 5, y, 8.75, 13.68, 3.65, 1.91
end
initials_pair 5, 85.62, 14.53, 32.24, 9.86, 1.91
signer 5, BUYER_1, 'date_signed', 73.41, 85.59, 16.98, 1.91, 'Buyer 1 date'

# ── Page 6: disclosure continued, WUI zone ────────────────────────────────
[3.97, 13.08, 42.3, 46.32].each { |y| initials_pair 6, y, 8.6, 13.8, 3.94, 2.39 }
# Buyers mark the one WUI statement that applies, so these are checkboxes:
# the signing page requires every initials box, which would force all three.
[30.09, 33.83, 37.5].each do |y|
  signer 6, BUYER_1, 'checkbox', 10.71, y, 6.61, 2.39, 'Buyer 1 WUI choice'
  signer 6, BUYER_2, 'checkbox', 18.12, y, 6.61, 2.39, 'Buyer 2 WUI choice'
end
standard_block 6, 82.41, 86.71, 2.39

# ── Pages 7-12, 14, 16: acknowledgement pages ─────────────────────────────
standard_block 7, 82.41, 86.71, 2.39    # Home Completion & Delivery
standard_block 8, 82.24, 86.55, 2.56    # Manufacturer's New Home Warranty
standard_block 9, 82.24, 86.55, 2.56    # Payment Disclosure
standard_block 10, 82.24, 86.55, 2.56   # HUD Dispute Resolution
field 11, 'contractor_ack_day', 'Licensed contractors: day', 26.06, 29.76, 9.86, 1.48, group: 'terms'
field 11, 'contractor_ack_month', 'Licensed contractors: month', 41.76, 29.52, 10.84, 1.48, group: 'terms'
field 11, 'contractor_ack_year', 'Licensed contractors: year (2 digits)', 55.57, 29.52, 2.96, 1.48, group: 'terms'
place 11, 'custom.contractor_ack_day', 'Licensed contractors: day', 'text', 26.06, 34.08, 9.86, 1.48, 'isCustomField' => true, 'isSignerField' => false
place 11, 'custom.contractor_ack_month', 'Licensed contractors: month', 'text', 41.87, 34.08, 10.84, 1.48, 'isCustomField' => true, 'isSignerField' => false
place 11, 'custom.contractor_ack_year', 'Licensed contractors: year', 'text', 55.57, 34.08, 2.96, 1.48, 'isCustomField' => true, 'isSignerField' => false
standard_block 11, 83.32, 87.62, 1.48   # Licensed Contractors
standard_block 12, 82.24, 86.55, 2.56   # Arbitration

# ── Page 13: Tires and Axles ──────────────────────────────────────────────
field 13, 'serial_number', 'Serial Number', 9.29, 16.91, 16.78, 1.48
field 13, 'tires_daytime_phone', 'Tires & axles: daytime phone', 27.78, 25.76, 30.57, 1.86, group: 'shipping', merge_from: 'contact.phone'
field 13, 'tires_evening_phone', 'Tires & axles: evening phone', 27.67, 27.82, 30.69, 1.86, group: 'shipping'
field 13, 'cell', 'Cell', 24.41, 29.97, 34.18, 1.86
field 13, 'email_1', 'Email Address 1', 20.61, 32.11, 38.1, 1.86
standard_block 13, 82.94, 87.24, 1.86

# ── Page 14: Shipping Directions & Map ────────────────────────────────────
[20.03, 22.36, 24.77, 27.11].each_with_index do |y, i|
  field 14, "shipping_address_#{i + 1}", "Shipping address line #{i + 1}", 16.2, y, 28.49, 1.95, group: 'shipping',
        merge_from: (i.zero? ? 'deal.delivery_street' : nil)
end
field 14, 'shipping_contact_name', 'Shipping contact name', 54.51, 20.03, 32.78, 1.95, group: 'shipping', merge_from: 'contact.full_name'
field 14, 'shipping_daytime_phone', 'Shipping contact daytime phone', 60.88, 22.36, 26.29, 1.95, group: 'shipping', merge_from: 'contact.phone'
field 14, 'shipping_evening_phone', 'Shipping contact evening phone', 60.76, 24.77, 26.29, 1.95, group: 'shipping'
field 14, 'shipping_mobile_phone', 'Shipping contact mobile phone', 59.84, 27.11, 27.1, 1.95, group: 'shipping', merge_from: 'contact.mobile_phone'
[67.8, 69.94, 72.09, 74.15].each_with_index do |y, i|
  field 14, "shipping_directions_#{i + 1}", "Directions line #{i + 1}", 15.75, y, 72.24, 1.95, group: 'shipping'
end
standard_block 14, 82.85, 87.15, 1.95

# ── Page 15: Title Information ────────────────────────────────────────────
field 15, 'title_dl_copy_attached', 'Copy of drivers license attached', 19.22, 17.73, 4.41, 2.3, type: 'checkbox', group: 'title'
[[21.12, 23.62, 26.12, 29.44], [32.83, 35.33, 37.83, 41.15], [44.55, 47.06, 49.56, nil]].each_with_index do |(name_y, dl_y, dob_y, join_y), i|
  n = i + 1
  field 15, "title_#{n}_name", "Title owner #{n}: name", 25.35, name_y, 55.92, 2.3, group: 'title', merge_from: (n == 1 ? 'contact.full_name' : nil)
  field 15, "title_#{n}_dl_number", "Title owner #{n}: drivers license #", 34.25, dl_y, 21.9, 2.3, group: 'title'
  field 15, "title_#{n}_dl_state", "Title owner #{n}: license state", 63.76, dl_y, 17.51, 2.3, group: 'title'
  field 15, "title_#{n}_dob", "Title owner #{n}: date of birth", 30.43, dob_y, 25.37, 2.23, group: 'title'
  field 15, "title_#{n}_ein", "Title owner #{n}: EIN", 63.76, dob_y, 17.51, 2.23, group: 'title'
  next unless join_y

  field 15, "title_join_#{n}_or", "Owners #{n}/#{n + 1} joined by OR", 19.22, join_y, 4.41, 2.3, type: 'checkbox', group: 'title'
  field 15, "title_join_#{n}_and", "Owners #{n}/#{n + 1} joined by AND", 33.57, join_y, 4.41, 2.3, type: 'checkbox', group: 'title'
  field 15, "title_join_#{n}_and_or", "Owners #{n}/#{n + 1} joined by AND/OR", 49.08, join_y, 4.29, 2.3, type: 'checkbox', group: 'title'
end
field 15, 'lien_holder', 'Lien holder', 35.08, 54.89, 39.47, 2.24, group: 'title'
field 15, 'lien_holder_address', 'Lien holder address', 32.53, 57.33, 42.02, 1.59, group: 'title'
field 15, 'lien_amount', 'Amount of lien', 37.96, 59.12, 36.37, 1.59, type: 'currency', group: 'title'
field 15, 'lien_date', 'Date of lien', 35.65, 60.91, 38.9, 1.59, group: 'title'
field 15, 'mso_mail_to', 'Mail MSO/Title to', 34.61, 65.58, 46.78, 2.3, group: 'title'
field 15, 'mso_city', 'MSO city', 23.61, 68.08, 19.71, 2.3, group: 'title'
field 15, 'mso_state', 'MSO state', 50.12, 68.08, 13.1, 2.3, group: 'title'
field 15, 'mso_zip', 'MSO ZIP', 68.29, 68.08, 13.1, 2.3, group: 'title'
standard_block 15, 82.5, 86.8, 2.3

# ── Page 16: Verification of Manufactured (HUD) Home Purchase ─────────────
standard_block 16, 83.89, 88.2, 0.91

# ── Build ─────────────────────────────────────────────────────────────────
pages = @placements.group_by { |p| p['page'] + 1 }.transform_values(&:size).sort.map { |pg, n| "p#{pg}:#{n}" }.join(' ')
per_signer = @placements.select { |p| p['isSignerField'] }.group_by { |p| p['signerIndex'] }.transform_values(&:size)
existing = company.agreement_templates.find_by(form_number: FORM_NUMBER, is_platform_template: false, is_deleted: false)

puts apply ? 'APPLYING' : 'PREVIEW: nothing will be changed (add --apply to create it)'
puts "#{company.name} (id #{company.id}, #{company.account_number})"
puts "#{existing ? "Rebuild template ##{existing.id}" : 'Create'} \"#{NAME}\": #{@placements.size} fields, #{@definitions.size} fillable, 16 pages"
puts "  by page: #{pages}"
puts "  signer fields: " + DEFAULT_SIGNERS.map { |s| "#{s[:label]} #{per_signer[s[:order_index]].to_i}" }.join(', ')
exit unless apply

key = "agreements/#{company.id}/documents/fdhc_indiana_pa_02_26.pdf"
document = PrivateFiles.put(File.binread(PDF_PATH), key: key, content_type: 'application/pdf')
category = company.agreement_categories.find_by(name: 'Sales Agreement')

template = existing || company.agreement_templates.build(form_number: FORM_NUMBER)
template.assign_attributes(
  name: NAME,
  description: 'Factory Direct Homes Center Indiana purchase agreement (form PA-02-26) with Addendum A, ' \
               'appliance and color sheets, disclosures, shipping and title pages. Prices fill from the deal; ' \
               'subtotals, total and unpaid balance calculate.',
  template_type: 'upload',
  status: 'active',
  form_type: 'purchase_agreement',
  state_code: 'IN',
  page_count: 16,
  document_url: document,
  document_urls: [],
  custom_field_definitions: @definitions.values,
  merge_field_placements: @placements,
  field_placements: [],
  default_signers: DEFAULT_SIGNERS.map(&:stringify_keys),
  agreement_category: category || template.agreement_category,
  is_platform_template: false,
  is_system_template: false,
  is_deleted: false
)
template.save!
puts "Saved template ##{template.id} (status #{template.status}). PDF at #{document}"

# frozen_string_literal: true

require 'open3'
require 'tempfile'

# Builds "Form 500 & Buyer Acknowledgement" for Coastal Breeze Homes: a clone of
# the Mississippi Form 500 platform template (form500_ms.rb, FORM500_MS) followed
# by the dealer's 10-page Closing Package as pages 4 to 13.
#
#   bin/rails runner script/agreement_templates/form500_ms_buyer_ack.rb RI-00027 --expect "Coastal Breeze"
#   bin/rails runner script/agreement_templates/form500_ms_buyer_ack.rb RI-00027 --expect "Coastal Breeze" --apply
#
# Preview is the default and changes nothing. --apply uploads the combined PDF
# and creates the template, or rebuilds it in place on a re-run so agreements
# already made from it keep their link. Pages 1 to 3 and their fields are copied
# from the live platform template, so run form500_ms.rb first in that environment.
#
# How a blank in the package gets filled:
#   - The preparer sees it on the Fill Form step, already filled from the deal,
#     contact or home when we hold the value (merge_from), and can change it.
#   - The buyer sees that value in the box at signing and can correct it.
#   - A value repeated across forms has ONE editable box, the first place it
#     appears. The signing page saves answers by field key, so two editable boxes
#     sharing a key would overwrite each other. The repeats print the same answer.
# Page 1 is the dealer's internal checklist, so nothing on it is buyer-editable.
# The notary block on the last page is completed by hand.

account = ARGV[0] or abort 'usage: bin/rails runner script/agreement_templates/form500_ms_buyer_ack.rb <account_number> --expect "<name>" [--apply]'
expect  = ARGV[ARGV.index('--expect') + 1] if ARGV.include?('--expect')
apply   = ARGV.include?('--apply')
abort 'Pass --expect "<part of the company name>" so the template cannot land on the wrong tenant.' if expect.blank?

company = Company.find_by(account_number: account) or abort "No company with account number #{account}."
unless company.name.downcase.include?(expect.downcase)
  abort "#{account} is \"#{company.name}\" (id #{company.id}), which does not match \"#{expect}\". Nothing changed."
end

source = AgreementTemplate.find_by(form_number: 'FORM500_MS', is_platform_template: true, is_deleted: false) or
  abort 'No FORM500_MS platform template here. Run script/agreement_templates/form500_ms.rb first.'

FORM500_PDF = File.expand_path('form500_ms.pdf', __dir__)
PACKAGE_PDF = File.expand_path('coastal_breeze_closing_package.pdf', __dir__)
FORM_NUMBER = 'FORM500_MS_BUYER_ACK'
NAME        = 'Form 500 & Buyer Acknowledgement'
FIRST_PAGE  = source.page_count.to_i # package page 1 is page FIRST_PAGE + 1

BUYER_1 = 0
BUYER_2 = 1
DEALER  = 2

PAGE_W = 612.0
PAGE_H = 792.0

@definitions = (source.custom_field_definitions || []).map(&:deep_dup).index_by { |d| d['key'] }
@placements  = (source.merge_field_placements || []).map(&:deep_dup)
@editable    = {}
cloned_fields = @placements.size

# x, y, width, height are PDF points from the top-left of the package page.
def place(page, key, label, type, box, extra = {})
  x, y, w, h = box
  @placements << {
    'id' => "cbh_#{@placements.size + 1}",
    'fieldKey' => key, 'fieldLabel' => label, 'fieldType' => type,
    'page' => FIRST_PAGE + page - 1,
    'x' => (x / PAGE_W * 100).round(2), 'y' => (y / PAGE_H * 100).round(2),
    'width' => (w / PAGE_W * 100).round(2), 'height' => (h / PAGE_H * 100).round(2)
  }.merge(extra)
end

# Boxes sit on a printed rule: from x0 to x1, with the rule at y `line`.
def on_line(x0, x1, line) = [x0 + 2, line - 12.5, x1 - x0 - 4, 12]

def define(page, key, label, merge_from, type: 'text', group: 'closing_package')
  @definitions[key] ||= {
    'key' => key, 'label' => label, 'type' => type, 'group' => group, 'page' => FIRST_PAGE + page,
    'required' => false, 'position' => @definitions.size + 1, 'filled_by' => 'preparer'
  }.tap { |d| d['merge_from'] = merge_from if merge_from }
end

# Preparer or buyer: editable by `owner` where it first appears, printed elsewhere.
def blank(page, key, label, x0, x1, line, section, from: nil, owner: BUYER_1)
  define(page, key, label, from)
  if @editable[key]
    place(page, "custom.#{key}", label, 'text', on_line(x0, x1, line), 'isCustomField' => true, 'isSignerField' => false)
  else
    @editable[key] = true
    place(page, "custom.#{key}", label, 'text_input', on_line(x0, x1, line),
          'isCustomField' => true, 'isSignerField' => true, 'signerIndex' => owner, 'section' => section)
  end
end

def auto(page, key, label, x0, x1, line)
  place(page, key, label, 'text', on_line(x0, x1, line), 'isCustomField' => false, 'isSignerField' => false)
end

def sign(page, who, x0, x1, line, label)
  place(page, 'signer.signature', label, 'signature', [x0 + 4, line - 19, [x1 - x0 - 8, 230].min, 18],
        'isCustomField' => false, 'isSignerField' => true, 'signerIndex' => who)
end

def dated(page, who, x0, x1, line, label)
  place(page, 'signer.date_signed', label, 'date_signed', on_line(x0, x1, line),
        'isCustomField' => false, 'isSignerField' => true, 'signerIndex' => who)
end

def initials(page, who, x0, x1, line, label)
  place(page, 'signer.initials', label, 'initials', [x0 + 8, line - 15, x1 - x0 - 16, 14],
        'isCustomField' => false, 'isSignerField' => true, 'signerIndex' => who)
end

def buyers_blank(page, x0, x1, line, section, label = 'Buyer(s)')
  blank page, 'cbh_buyer_names', label, x0, x1, line, section, from: 'deal.buyer_names'
end

def date_blank(page, x0, x1, line, section)
  blank page, 'cbh_date', 'Agreement date', x0, x1, line, section, from: 'date.today'
end

def home_blank(page, x0, x1, line, section)
  blank page, 'cbh_home', 'Home: year, size, manufacturer, serial number', x0, x1, line, section, from: 'vehicle.home_description'
end

def site_blank(page, x0, x1, line, section)
  blank page, 'cbh_site_address', 'Site address (full)', x0, x1, line, section, from: 'deal.delivery_full_address'
end

# Two buyers with driver's licenses, then the dealer's signature and date.
def license_block(page, name, x0, mid0, mid1, x1, dealer_x1, dealer_date_x0, lines)
  [[BUYER_1, 'cbh_license_1', 'Buyer 1'], [BUYER_2, 'cbh_license_2', 'Buyer 2']].each_with_index do |(who, key, buyer), i|
    sign page, who, x0, mid0, lines[i], "#{buyer} signature (#{name})"
    blank page, key, "#{buyer} driver's license number", mid1, x1, lines[i], name, owner: who
  end
  sign page, DEALER, x0, dealer_x1, lines[2], "Member / Manager / Director (#{name})"
  dated page, DEALER, dealer_date_x0, x1, lines[2], "Dealer date (#{name})"
end

# ── CBH-02 Credit Approval Acknowledgment ─────────────────────────────────
s = 'Credit Approval Acknowledgment'
buyers_blank 2, 91.5, 293.2, 140.2, s
date_blank 2, 345.8, 564, 140.2, s
auto 2, 'company.name', 'Dealer', 82.5, 293.2, 159.8
blank 2, 'cbh_lender', 'Lender', 355.5, 564, 159.8, s, from: 'deal.lender_name'
initials 2, BUYER_1, 126, 190.5, 326.2, 'Buyer 1 initials (approval expires)'
initials 2, BUYER_2, 208.5, 273, 326.2, 'Buyer 2 initials (approval expires)'
[[BUYER_1, 637.5, 'Buyer 1'], [BUYER_2, 680.2, 'Buyer 2'], [DEALER, 723, 'Dealer representative']].each do |who, line, name|
  sign 2, who, 48, 406.5, line, "#{name} signature (credit approval)"
  dated 2, who, 429, 564, line, "#{name} date (credit approval)"
end

# ── CBH-03 Agreement Not to Occupy ────────────────────────────────────────
s = 'Agreement Not to Occupy'
buyers_blank 3, 94.5, 561, 164.2, s
blank 3, 'cbh_site_street', 'Site street address', 111, 561, 186.8, s, from: 'deal.delivery_street'
blank 3, 'cbh_site_city_state_zip', 'Site city, state, ZIP', 127.5, 293.2, 209.2, s, from: 'deal.delivery_city_state_zip'
date_blank 3, 345.8, 561, 209.2, s
[[BUYER_1, 610.5, 'Buyer 1'], [BUYER_2, 663.8, 'Buyer 2'], [DEALER, 717, 'Witness']].each do |who, line, name|
  sign 3, who, 51, 403.5, line, "#{name} signature (not to occupy)"
  dated 3, who, 426, 561, line, "#{name} date (not to occupy)"
end

# ── CBH-04 Responsibilities Agreement (2 pages) ───────────────────────────
s = 'Responsibilities Agreement'
buyers_blank 4, 111, 561, 161.2, s, 'Customer(s)'
home_blank 4, 255.8, 561, 183, s
site_blank 4, 157.5, 561, 204.8, s
license_block 5, s, 51, 294.8, 317.2, 561, 403.5, 426, [610.5, 663.8, 717]

# ── CBH-05 No Service Warranty Agreement ──────────────────────────────────
s = 'No Service Warranty Agreement'
home_blank 6, 267.8, 561, 148.5, s
site_blank 6, 93.8, 561, 170.2, s
license_block 6, s, 51, 294.8, 317.2, 561, 403.5, 426, [631.5, 674.2, 717]

# ── CBH-06 Mold Disclosure and Waiver ─────────────────────────────────────
s = 'Mold Disclosure and Waiver'
buyers_blank 7, 160.5, 565.5, 120.8, s
home_blank 7, 263.2, 565.5, 140.2, s
site_blank 7, 89.2, 565.5, 159.8, s
initials 7, BUYER_1, 123.8, 183.8, 339.8, 'Buyer 1 initials (mold inspections)'
initials 7, BUYER_2, 201, 261, 339.8, 'Buyer 2 initials (mold inspections)'
license_block 7, s, 46.5, 294.8, 317.2, 565.5, 408, 430.5, [647.2, 687.8, 728.2]

# ── CBH-07 Hold Harmless Agreement ────────────────────────────────────────
s = 'Hold Harmless Agreement'
buyers_blank 8, 94.5, 561, 165.8, s
home_blank 8, 255.8, 561, 188.2, s
site_blank 8, 111, 293.2, 210.8, s
date_blank 8, 345.8, 561, 210.8, s
license_block 8, s, 51, 294.8, 317.2, 561, 403.5, 426, [610.5, 663.8, 717]

# ── CBH-08 Arbitration Agreement ──────────────────────────────────────────
s = 'Arbitration Agreement'
buyers_blank 9, 111, 293.2, 132, s, 'Customer(s)'
date_blank 9, 345.8, 561, 132, s
license_block 9, s, 51, 294.8, 317.2, 561, 403.5, 426, [640.5, 682.5, 724.5]

# ── CBH-09 Buyer's Power of Attorney (notary block completed by hand) ─────
s = "Buyer's Power of Attorney"
home_blank 10, 255.8, 561, 253.5, s
blank 10, 'cbh_home_land_description', 'Description of home, or land and home', 225, 561, 276, s, from: 'vehicle.home_type'
[[BUYER_1, 387.8, 'Buyer 1'], [BUYER_2, 442.5, 'Buyer 2']].each do |who, line, name|
  sign 10, who, 51, 291, line, "#{name} signature (power of attorney)"
  sign 10, DEALER, 321, 561, line, "Witness for #{name} (power of attorney)"
end

# ── CBH-01 Closing Package Checklist (internal: dealer side only) ─────────
buyers_blank 1, 99.8, 293.2, 149.2, 'Closing Package Checklist', 'Customer'
auto 1, 'vehicle.serial_number', 'Full serial number', 402, 561, 149.2
auto 1, 'deal.owner_name', 'Salesperson', 111, 293.2, 168.8
auto 1, 'vehicle.stock_number', 'Stock number', 385.5, 561, 168.8
auto 1, 'deal.close_date', 'Closing date', 111.8, 293.2, 188.2
auto 1, 'vehicle.year_size', 'Home year / size', 397.5, 561, 188.2
CHECKLIST = {
  'Credit Approval Acknowledgment' => 247.5, 'Agreement Not to Occupy' => 267, 'Responsibilities Agreement' => 286.5,
  'No Service Warranty Agreement' => 306, 'Mold Disclosure and Waiver' => 325.5, 'Hold Harmless Agreement' => 345,
  'Arbitration Agreement' => 364.5, "Buyer's Power of Attorney" => 384, 'Original Form 100 / Bill of Sale' => 421.5,
  'Promise Sheet' => 441, 'Copy of deposit slip' => 460.5, 'Title application' => 480, 'Flood certification completed' => 499.5,
  "Copy of driver's license and Social Security card" => 519, 'Landlord waiver' => 538.5,
  'Bids and quotes on add-on options' => 558, 'Gross profit worksheet' => 577.5
}.freeze
CHECKLIST.each_with_index do |(item, line), i|
  [['sales', 'Salesperson', 417], ['manager', 'Manager', 495]].each do |col, who, x0|
    key = "cbh_check_#{i + 1}_#{col}"
    define 1, key, "#{item}: #{who}", nil, type: 'checkbox', group: 'closing_checklist'
    place 1, "custom.#{key}", "#{item}: #{who}", 'checkbox', [x0 + 20, line - 13, 14, 12], 'isCustomField' => true, 'isSignerField' => false
  end
end
auto 1, 'deal.owner_name', 'Sales representative', 51, 403.5, 666
auto 1, 'date.today', 'Sales representative date', 426, 561, 666
sign 1, DEALER, 51, 403.5, 708.8, 'Manager signature (checklist)'
dated 1, DEALER, 426, 561, 708.8, 'Manager date (checklist)'

# ── Build ─────────────────────────────────────────────────────────────────
# qpdf, not CombinePDF: form500_ms.pdf has optional content layers CombinePDF refuses.
def npages(path)
  out, status = Open3.capture2('qpdf', '--show-npages', path)
  status.success? or abort "qpdf could not read #{path}"
  out.to_i
end
form500_pages = npages(FORM500_PDF)
abort "Platform template says #{FIRST_PAGE} pages but form500_ms.pdf has #{form500_pages}." if form500_pages != FIRST_PAGE
page_count = form500_pages + npages(PACKAGE_PDF)

pages = @placements.group_by { |p| p['page'] + 1 }.transform_values(&:size).sort.map { |pg, n| "p#{pg}:#{n}" }.join(' ')
per_signer = @placements.select { |p| p['isSignerField'] }.group_by { |p| p['signerIndex'] }.transform_values(&:size)
signers = source.default_signers.map(&:stringify_keys)
existing = AgreementTemplate.find_by(company_id: company.id, form_number: FORM_NUMBER, is_deleted: [false, nil])

puts apply ? 'APPLYING' : 'PREVIEW: nothing will be changed (add --apply to create it)'
puts "Dealer: #{company.name} (id #{company.id}, #{company.account_number})"
puts "Cloned from platform template ##{source.id} \"#{source.name}\": #{cloned_fields} fields"
puts "#{existing ? "Rebuild template ##{existing.id}" : 'Create template'} \"#{NAME}\": " \
     "#{@placements.size} fields, #{@definitions.size} fillable, #{page_count} pages"
puts "  by page: #{pages}"
puts '  signer fields: ' + signers.map { |x| "#{x['label']} #{per_signer[x['order_index'].to_i].to_i}" }.join(', ')
puts "  auto-filled: #{@definitions.values.count { |d| d['merge_from'] }} of #{@definitions.size}"
exit unless apply

combined = Tempfile.new(['form500_ms_buyer_ack', '.pdf'])
_, err, status = Open3.capture3('qpdf', '--empty', '--pages', FORM500_PDF, PACKAGE_PDF, '--', combined.path)
abort "qpdf could not join the PDFs: #{err}" unless [0, 3].include?(status.exitstatus) && npages(combined.path) == page_count
key = "agreements/#{company.id}/documents/form500_ms_buyer_ack.pdf"
document = PrivateFiles.put(File.binread(combined.path), key: key, content_type: 'application/pdf')
combined.close!

template = existing || AgreementTemplate.new(company_id: company.id, form_number: FORM_NUMBER)
template.assign_attributes(
  name: NAME,
  description: 'Mississippi Form 500 purchase agreement followed by the Coastal Breeze Closing Package: checklist, ' \
               'Credit Approval Acknowledgment, Agreement Not to Occupy, Responsibilities, No Service Warranty, Mold ' \
               "Disclosure, Hold Harmless, Arbitration and Buyer's Power of Attorney. Blanks fill from the deal; the " \
               'preparer or the buyer can complete or correct them.',
  template_type: 'upload',
  status: 'active',
  form_type: 'purchase_agreement',
  state_code: 'MS',
  page_count: page_count,
  document_url: document,
  document_urls: [],
  custom_field_definitions: @definitions.values,
  merge_field_placements: @placements,
  field_placements: [],
  default_signers: signers,
  is_platform_template: false,
  is_system_template: false,
  is_deleted: false
)
template.save!
puts "Saved template ##{template.id} for #{company.name} (status #{template.status}). PDF at #{document}"

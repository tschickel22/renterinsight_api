# frozen_string_literal: true

require 'open3'
require 'tempfile'

# Builds "Form 500 & Buyer Acknowledgement" for one dealer: a clone of the
# Mississippi Form 500 platform template (form500_ms.rb, form number
# FORM500_MS) with the Dealers Network buyer acknowledgement packet appended
# as pages 4 to 12. The template belongs to the dealer, not the platform.
#
#   bin/rails runner script/agreement_templates/form500_ms_buyer_ack.rb RI-00027 --expect "Coastal Breeze"
#   bin/rails runner script/agreement_templates/form500_ms_buyer_ack.rb RI-00027 --expect "Coastal Breeze" --apply
#
# Preview is the default and changes nothing. --apply uploads the combined PDF
# and creates the template (or rebuilds it in place on a re-run, so agreements
# already made from it keep their link). Pages 1 to 3 and their fields are
# copied from the live platform template at run time, so run form500_ms.rb
# first in that environment.
#
# The packet (buyer_ack_dealers_network.pdf beside this file) is the dealer's
# scanned copy, straightened and re-saved at 150 dpi:
#   4  Buyers Acknowledgment and Agreement Not To Occupy  (buyers sign, dealer witnesses)
#   5  Credit Approval Acknowledgment                      (buyers initial and sign, dealer signs)
#   6  Dealer's Acknowledgment                             (dealer signs)
#   7  Dealers Network Land/Home Checklist                 (customer name fills; rest by hand)
#   8-12 Dealers Network deal checklists                   (printed as they are, filled by hand)

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
PACKET_PDF  = File.expand_path('buyer_ack_dealers_network.pdf', __dir__)
FORM_NUMBER = 'FORM500_MS_BUYER_ACK'
NAME        = 'Form 500 & Buyer Acknowledgement'
FIRST_PAGE  = source.page_count.to_i # packet page 1 is page FIRST_PAGE + 1

BUYER_1 = 0
BUYER_2 = 1
DEALER  = 2

PAGE_W = 612.0
PAGE_H = 792.0

@definitions = (source.custom_field_definitions || []).map(&:deep_dup).index_by { |d| d['key'] }
@placements  = (source.merge_field_placements || []).map(&:deep_dup)
cloned_fields = @placements.size

# Coordinates are PDF points from the top-left corner of the packet page: x, y, width, height.
def place(packet_page, key, label, type, x, y, w, h, extra = {})
  @placements << {
    'id' => "ack_#{@placements.size + 1}",
    'fieldKey' => key, 'fieldLabel' => label, 'fieldType' => type,
    'page' => FIRST_PAGE + packet_page - 1,
    'x' => (x / PAGE_W * 100).round(2), 'y' => (y / PAGE_H * 100).round(2),
    'width' => (w / PAGE_W * 100).round(2), 'height' => (h / PAGE_H * 100).round(2)
  }.merge(extra)
end

def field(packet_page, key, label, x, y, w, h = 11.7, type: 'text', group: 'buyer_acknowledgement', merge_from: nil)
  @definitions[key] ||= {
    'key' => key, 'label' => label, 'type' => type, 'group' => group, 'page' => FIRST_PAGE + packet_page,
    'required' => false, 'position' => @definitions.size + 1, 'filled_by' => 'preparer'
  }.tap { |d| d['merge_from'] = merge_from if merge_from }
  place(packet_page, "custom.#{key}", label, type, x, y, w, h, 'isCustomField' => true, 'isSignerField' => false)
end

def merge(packet_page, key, label, x, y, w, h = 11.7, type: 'text')
  place(packet_page, key, label, type, x, y, w, h, 'isCustomField' => false, 'isSignerField' => false)
end

def signer(packet_page, who, type, x, y, w, h, label)
  place(packet_page, "signer.#{type}", label, type, x, y, w, h, 'isCustomField' => false, 'isSignerField' => true, 'signerIndex' => who)
end

# ── Packet page 1: Buyers Acknowledgment And Agreement Not To Occupy ──────
merge 1, 'deal.delivery_street', 'Site address', 162, 106, 186
merge 1, 'deal.delivery_city', 'Site city', 182, 122, 74
merge 1, 'deal.delivery_state', 'Site state', 258, 122, 20
merge 1, 'deal.delivery_zip', 'Site ZIP', 280, 122, 40
signer 1, BUYER_1, 'signature', 120, 424, 162, 16, 'Buyer 1 signature (not to occupy)'
signer 1, BUYER_1, 'date_signed', 334, 429, 86, 11, 'Buyer 1 date (not to occupy)'
signer 1, BUYER_2, 'signature', 120, 457, 162, 16, 'Buyer 2 signature (not to occupy)'
signer 1, BUYER_2, 'date_signed', 334, 462, 86, 11, 'Buyer 2 date (not to occupy)'
signer 1, DEALER, 'signature', 122, 505, 160, 16, 'Witness signature'
signer 1, DEALER, 'date_signed', 336, 510, 84, 11, 'Witness date'

# ── Packet page 2: Credit Approval Acknowledgment ─────────────────────────
merge 2, 'date.today', 'Date', 93, 117, 60, type: 'date'
merge 2, 'company.name', 'Dealer', 346, 143, 146
field 2, 'lender_name', 'Lender', 108, 171, 214
signer 2, BUYER_1, 'initials', 50, 296, 36, 13, 'Buyer 1 initials (expiration date)'
signer 2, BUYER_2, 'initials', 104, 296, 36, 13, 'Buyer 2 initials (expiration date)'
signer 2, BUYER_1, 'signature', 42, 564, 150, 16, 'Buyer 1 signature (credit approval)'
signer 2, BUYER_1, 'date_signed', 242, 569, 74, 11, 'Buyer 1 date (credit approval)'
signer 2, BUYER_2, 'signature', 42, 608, 150, 16, 'Buyer 2 signature (credit approval)'
signer 2, BUYER_2, 'date_signed', 246, 613, 70, 11, 'Buyer 2 date (credit approval)'
signer 2, DEALER, 'signature', 42, 653, 150, 16, 'Dealer signature (credit approval)'
signer 2, DEALER, 'date_signed', 257, 658, 54, 11, 'Dealer date (credit approval)'

# ── Packet page 3: Dealer's Acknowledgment ────────────────────────────────
merge 3, 'company.name', 'Dealer', 112, 102, 200
field 3, 'buyer_names', 'Buyer(s)', 160, 134, 160, group: 'buyer', merge_from: 'contact.full_name'
field 3, 'lender_name', 'Lender', 112, 166, 182
signer 3, DEALER, 'signature', 72, 467, 182, 16, "Dealer signature (dealer's acknowledgment)"
field 3, 'dealer_signer_title', 'Title of the dealer signing', 84, 505, 170
signer 3, DEALER, 'date_signed', 88, 537, 166, 11, "Dealer date (dealer's acknowledgment)"

# ── Packet page 4: Land/Home Checklist ────────────────────────────────────
field 4, 'buyer_names', 'Buyer(s)', 135, 167, 186, group: 'buyer', merge_from: 'contact.full_name'

# ── Build ─────────────────────────────────────────────────────────────────
# qpdf, not CombinePDF: form500_ms.pdf has optional content layers, which
# CombinePDF refuses to read.
def npages(path)
  out, status = Open3.capture2('qpdf', '--show-npages', path)
  status.success? or abort "qpdf could not read #{path}"
  out.to_i
end
form500_pages = npages(FORM500_PDF)
packet_pages  = npages(PACKET_PDF)
abort "Platform template says #{FIRST_PAGE} pages but form500_ms.pdf has #{form500_pages}." if form500_pages != FIRST_PAGE
page_count = form500_pages + packet_pages

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
puts '  signer fields: ' + signers.map { |s| "#{s['label']} #{per_signer[s['order_index'].to_i].to_i}" }.join(', ')
exit unless apply

combined = Tempfile.new(['form500_ms_buyer_ack', '.pdf'])
_, err, status = Open3.capture3('qpdf', '--empty', '--pages', FORM500_PDF, PACKET_PDF, '--', combined.path)
abort "qpdf could not join the PDFs: #{err}" unless [0, 3].include?(status.exitstatus) && npages(combined.path) == page_count
key = "agreements/#{company.id}/documents/form500_ms_buyer_ack.pdf"
document = PrivateFiles.put(File.binread(combined.path), key: key, content_type: 'application/pdf')
combined.close!

template = existing || AgreementTemplate.new(company_id: company.id, form_number: FORM_NUMBER)
template.assign_attributes(
  name: NAME,
  description: 'Mississippi Form 500 purchase agreement (same fields as the platform Form 500) followed by the ' \
               'Dealers Network buyer acknowledgement packet: Agreement Not To Occupy, Credit Approval ' \
               "Acknowledgment, Dealer's Acknowledgment, Land/Home Checklist and the deal checklists.",
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

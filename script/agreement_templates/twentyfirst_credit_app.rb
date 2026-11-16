# frozen_string_literal: true

# Builds 21st Mortgage's 5-page credit application (v. 12/20/2023) as an
# agreement template the buyers fill in and sign on the signing page.
#
#   bin/rails runner script/agreement_templates/twentyfirst_credit_app.rb RI-00027 --expect "Coastal Breeze"
#   bin/rails runner script/agreement_templates/twentyfirst_credit_app.rb RI-00027 --expect "Coastal Breeze" --apply
#
# Preview is the default and changes nothing. --apply uploads the PDF and
# creates the template, or rebuilds it in place on a re-run so agreements
# already sent from it keep their link. --expect must match the company name
# (account numbers come from company ids, which differ per environment).
#
# The form says it "must be completed and signed by the applicant(s) only", so
# nothing is filled by the dealer: every box belongs to a signer. Signer 1 is the
# applicant (column A plus the property, expense and assistance sections), signer 2
# the co-applicant (column B), signer 3 an optional non-applicant spouse (waiver on
# page 5). Picking 1 or 2 signers in the builder drops the later ones. Typed boxes
# and checkboxes are optional on the signing page; only signatures are required.
# Names, contact details, the home site address and the down payment start filled
# from the deal or contact (each box's prefillFrom), and the buyers can change them.
#
# Box positions come from twentyfirst_credit_app_1223.json, generated from the
# PDF's own label coordinates by twentyfirst_credit_app_layout.py (see its header).

account = ARGV[0] or abort 'usage: bin/rails runner script/agreement_templates/twentyfirst_credit_app.rb <account_number> --expect "<name>" [--apply]'
expect  = ARGV[ARGV.index('--expect') + 1] if ARGV.include?('--expect')
apply   = ARGV.include?('--apply')
abort 'Pass --expect "<part of the company name>" so the template cannot land on the wrong tenant.' if expect.blank?

company = Company.find_by(account_number: account) or abort "No company with account number #{account}."
unless company.name.downcase.include?(expect.downcase)
  abort "#{account} is \"#{company.name}\" (id #{company.id}), which does not match \"#{expect}\". Nothing changed."
end

dir         = ENV['TEMPLATE_DIR'].presence || __dir__
PDF_PATH    = File.join(dir, 'twentyfirst_credit_app_1223.pdf')
LAYOUT_PATH = File.join(dir, 'twentyfirst_credit_app_1223.json')
FORM_NUMBER = 'TWENTYFIRST_CREDIT_APP_1223'
NAME        = '21st Mortgage Credit Application'

DEFAULT_SIGNERS = [
  { role: 'signer', order_index: 0, label: 'Applicant' },
  { role: 'signer', order_index: 1, label: 'Co-Applicant' },
  { role: 'signer', order_index: 2, label: 'Non-Applicant Spouse' }
].freeze

placements = JSON.parse(File.read(LAYOUT_PATH))
keys = placements.reject { |p| p['fieldKey'].start_with?('signer.') }.map { |p| p['fieldKey'] }
abort "Duplicate box keys: #{keys.tally.select { |_, n| n > 1 }.keys.first(5)}" if keys.uniq.size != keys.size

by_page   = placements.group_by { |p| p['page'] + 1 }.transform_values(&:size).sort.map { |pg, n| "p#{pg}:#{n}" }.join(' ')
by_signer = placements.group_by { |p| p['signerIndex'] }.transform_values(&:size)
existing  = company.agreement_templates.find_by(form_number: FORM_NUMBER, is_platform_template: false, is_deleted: false)

puts apply ? 'APPLYING' : 'PREVIEW: nothing will be changed (add --apply to create it)'
puts "#{company.name} (id #{company.id}, #{company.account_number})"
puts "#{existing ? "Rebuild template ##{existing.id}" : 'Create'} \"#{NAME}\": #{placements.size} boxes, 5 pages"
puts "  by page: #{by_page}"
puts '  by signer: ' + DEFAULT_SIGNERS.map { |s| "#{s[:label]} #{by_signer[s[:order_index]].to_i}" }.join(', ')
exit unless apply

key = "agreements/#{company.id}/documents/twentyfirst_credit_app_1223.pdf"
document = PrivateFiles.put(File.binread(PDF_PATH), key: key, content_type: 'application/pdf')

template = existing || company.agreement_templates.build(form_number: FORM_NUMBER)
template.assign_attributes(
  name: NAME,
  description: "21st Mortgage's credit application (v. 12/20/2023). The applicant and co-applicant complete it " \
               'on the signing page and sign on page 5; a non-applicant spouse can sign the waiver. Names, ' \
               'contact details, the home site address and the down payment start filled from the deal, ' \
               'and the buyers can change them.',
  template_type: 'upload',
  status: 'active',
  form_type: 'other',
  page_count: 5,
  document_url: document,
  document_urls: [],
  custom_field_definitions: [],
  merge_field_placements: placements,
  field_placements: [],
  default_signers: DEFAULT_SIGNERS.map(&:stringify_keys),
  is_platform_template: false,
  is_system_template: false,
  is_deleted: false
)
template.save!
puts "Saved template ##{template.id} (status #{template.status}). PDF at #{document}"

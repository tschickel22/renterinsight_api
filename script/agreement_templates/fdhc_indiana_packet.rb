# frozen_string_literal: true

# Installs Factory Direct Homes Center's agreement package: their Indiana
# purchase agreement in their own wording (from their quote desk), which the
# platform fills from the deal and its Deal Sheet, with Schedule A and the
# Color and Finish Selections in place of their option and color pages
# (Agreements::PacketRenderer). Everything about it is in the JSON beside this
# file: the document, the page order, and what fills each blank.
#
#   bin/rails runner script/agreement_templates/fdhc_indiana_packet.rb RI-00004 --expect "Factory Direct"
#   bin/rails runner script/agreement_templates/fdhc_indiana_packet.rb RI-00004 --expect "Factory Direct" --apply
#
# Preview is the default and changes nothing. --apply creates the template
# (or updates it in place on a re-run, so agreements already made from it
# keep their link). --expect must match the company name: account numbers
# come from company ids, which differ per environment.
#
# Another dealer's package is the same shape: their contract converted to the
# document model, and a fills map onto Agreements::PacketValues names.

account = ARGV[0] or abort 'usage: bin/rails runner script/agreement_templates/fdhc_indiana_packet.rb <account_number> --expect "<name>" [--apply]'
expect  = ARGV[ARGV.index('--expect') + 1] if ARGV.include?('--expect')
apply   = ARGV.include?('--apply')
abort 'Pass --expect "<part of the company name>" so the template cannot land on the wrong tenant.' if expect.blank?

company = Company.find_by(account_number: account) or abort "No company with account number #{account}."
unless company.name.downcase.include?(expect.downcase)
  abort "#{account} is \"#{company.name}\" (id #{company.id}), which does not match \"#{expect}\". Nothing changed."
end

installer = Agreements::PackageInstaller.new(company, 'fdhc_indiana')
puts apply ? 'APPLYING' : 'PREVIEW: nothing will be changed (add --apply to create it)'
puts installer.summary
exit unless apply

template = installer.install!
puts "Saved template ##{template.id} (status #{template.status})."

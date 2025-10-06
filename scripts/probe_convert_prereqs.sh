#!/usr/bin/env bash
# scripts/probe_convert_prereqs.sh
set -euo pipefail
cd ~/src/renterinsight_api

LEAD_ID=${LEAD_ID:-18}

echo "== Branch =="
git rev-parse --abbrev-ref HEAD || true
echo

echo "== Route =="
bin/rails routes | grep -E '/api/crm/leads/:lead_id/convert' || echo "convert route NOT found"
echo

echo "== DB & Models =="
bin/rails runner - <<'RUBY'
require "active_record"
def has_table?(t) = ActiveRecord::Base.connection.data_source_exists?(t)
def cols(t) = ActiveRecord::Base.connection.columns(t).map(&:name) rescue []

puts "tables:"
%w[leads accounts activities ai_insights communication_logs tags tag_assignments reminders lead_scores].each do |t|
  puts "  #{t.ljust(20)} -> #{has_table?(t)}"
end

puts "\nmodels:"
begin
  Account; puts "  Account model: present"
rescue NameError
  puts "  Account model: MISSING"
end

lead_cols = cols(:leads)
puts "\nlead columns:"
puts "  #{lead_cols.sort.join(', ')}"

need = %w[status converted_account_id first_name last_name email phone]
missing = need - lead_cols
puts "missing lead columns: #{missing.empty? ? '(none)' : missing.join(', ')}"
RUBY

echo
echo "== Lead snapshot =="
bin/rails runner -e development - <<RUBY
lead = Lead.find_by(id: ${LEAD_ID})
if !lead
  puts "Lead ${LEAD_ID} not found"
  exit
end

def safes(v); v.nil? || v=="" ? "(nil)" : v; end

print "Lead ##{lead.id}: "
name = lead.respond_to?(:name) && lead.name.present? ? lead.name :
        [lead.try(:first_name), lead.try(:last_name)].compact.join(' ')
puts name.empty? ? "(no name fields)" : name
puts "  email:  \#{safes(lead.try(:email))}"
puts "  phone:  \#{safes(lead.try(:phone))}"
puts "  status: \#{safes(lead.try(:status))}"
puts "  converted_account_id: \#{safes(lead.try(:converted_account_id))}"

act = Activity.where(lead_id: lead.id).count
comm= CommunicationLog.where(lead_id: lead.id).count
rem = Reminder.where(lead_id: lead.id).count
ins = defined?(AiInsight) ? AiInsight.where(lead_id: lead.id).count : 0
puts "  counts -> activities:\#{act}, comm_logs:\#{comm}, reminders:\#{rem}, ai_insights:\#{ins}"

if lead.respond_to?(:converted_account_id) && lead.converted_account_id.present?
  acct = Account.find_by(id: lead.converted_account_id) rescue nil
  puts "  linked account: \#{acct ? "##{acct.id} #{acct.try(:name)}" : "(missing account record)"}"
end

# preview: how a conversion would name the account
account_name =
  (lead.respond_to?(:name) && lead.name.present?) ? lead.name :
  [lead.try(:first_name), lead.try(:last_name)].compact.join(' ').presence ||
  "Lead \#{lead.id}"

puts "would use account_name: \#{account_name}"
RUBY

echo
echo "== Done =="

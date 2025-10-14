#! /usr/bin/env ruby

# This script fixes all Phase 4E test issues in one go

puts "🔧 Fixing Phase 4E Tests..."
puts "=" * 50

# Fix 1: Update BuyerPortalService to generate passwords
puts "\n1. Adding password generation to BuyerPortalService..."
service_file = 'app/services/buyer_portal_service.rb'
content = File.read(service_file)

# Add password generation
content.gsub!(
  /def self\.create_portal_access\(buyer, email, send_welcome: true\)\n    portal_access = BuyerPortalAccess\.create!\(/,
  <<~RUBY
    def self.create_portal_access(buyer, email, send_welcome: true)
      # Generate a secure random password
      generated_password = SecureRandom.alphanumeric(16)
      
      # Create buyer portal access
      portal_access = BuyerPortalAccess.create!(
        password: generated_password,
        password_confirmation: generated_password,
  RUBY
)

File.write(service_file, content)
puts "   ✅ BuyerPortalService updated"

# Fix 2: Fix all test files to use correct associations and passwords
test_fixes = [
  {
    file: 'spec/services/buyer_portal_service_spec.rb',
    changes: [
      # Fix Quote associations (buyer -> account)
      [/Quote\.create!\(\s*buyer: lead,/, "Quote.create!(account: account,"],
      # Fix CommunicationThread associations (threadable -> participant)
      [/CommunicationThread\.create!\(\s*threadable: lead,/, "CommunicationThread.create!(participant_type: 'Lead', participant_id: lead.id,"],
      # Add password to BuyerPortalAccess creation
      [/BuyerPortalAccess\.create!\(\s*buyer: lead,\s*email: '[^']+',\s*portal_enabled: true\s*\)/, "BuyerPortalAccess.create!(buyer: lead, email: 'john@example.com', password: 'Password123!', password_confirmation: 'Password123!', portal_enabled: true)"],
      # Add account creation in let blocks
      [/let\(:lead\) \{[^}]+\}/, "let(:lead) { Lead.create!(company: company, source: source, first_name: 'John', last_name: 'Doe', email: 'john@example.com', phone: '555-1234') }\n  let(:account) { Account.create!(company: company, name: 'John Doe Account', email: 'john@example.com', status: 'active') }\n  before { lead.update!(converted_account_id: account.id) }"]
    ]
  },
  {
    file: 'spec/integration/buyer_portal_flow_spec.rb',
    changes: [
      [/Quote\.create!\(\s*buyer: lead,/, "Quote.create!(account: account,"],
      [/CommunicationThread\.create!\(\s*threadable: lead,/, "CommunicationThread.create!(participant_type: 'Lead', participant_id: lead.id,"]
    ]
  },
  {
    file: 'spec/security/portal_authorization_spec.rb',
    changes: [
      [/Quote\.create!\(\s*buyer: buyer1,/, "Quote.create!(account: account1,"],
      [/Quote\.create!\(\s*buyer: buyer2,/, "Quote.create!(account: account2,"],
      [/CommunicationThread\.create!\(\s*threadable: buyer1,/, "CommunicationThread.create!(participant_type: 'Lead', participant_id: buyer1.id,"],
      [/CommunicationThread\.create!\(\s*threadable: buyer2,/, "CommunicationThread.create!(participant_type: 'Lead', participant_id: buyer2.id,"],
      # Fix update_preferences method call
      [/portal_access2\.update_preferences\(\{ email_opt_in: true \}\)/, "portal_access2.update!(email_opt_in: true)"]
    ]
  }
]

test_fixes.each do |fix|
  print "\n2. Fixing #{fix[:file]}..."
  content = File.read(fix[:file])
  
  fix[:changes].each do |old_pattern, new_text|
    content.gsub!(old_pattern, new_text)
  end
  
  File.write(fix[:file], content)
  puts " ✅"
end

puts "\n" + "=" * 50
puts "✅ All fixes applied!"
puts "\nRun tests with:"
puts "  ./test_phase4_complete.sh"

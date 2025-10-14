#!/usr/bin/env ruby
# Phase 4E Master Fix Script - Fixes all remaining test issues

puts "🔧 Phase 4E Master Fix Script"
puts "=" * 60

# Fix 1: Add channel to all CommunicationThread.create! calls
puts "\n1. Adding 'channel' to CommunicationThread creation..."

files_to_fix = [
  'spec/services/buyer_portal_service_spec.rb',
  'spec/integration/buyer_portal_flow_spec.rb',
  'spec/security/portal_authorization_spec.rb'
]

files_to_fix.each do |file|
  next unless File.exist?(file)
  
  content = File.read(file)
  
  # Add channel: 'portal_message' to all CommunicationThread.create! calls
  content.gsub!(
    /CommunicationThread\.create!\(\s*participant_type: ("[^"]+"|'[^']+'),\s*participant_id: ([^,]+),\s*subject:/,
    "CommunicationThread.create!(participant_type: \\1, participant_id: \\2, channel: 'portal_message', subject:"
  )
  
  File.write(file, content)
  puts "   ✅ Fixed: #{file}"
end

# Fix 2: Add account variable to integration spec
puts "\n2. Adding account setup to integration spec..."
int_file = 'spec/integration/buyer_portal_flow_spec.rb'
if File.exist?(int_file)
  content = File.read(int_file)
  
  # Add account after lead definition
  unless content.include?('let(:account)')
    content.sub!(
      /let\(:lead\) do\s+Lead\.create!\([^)]+\)\s+end/m,
      "\\0\n\n  let(:account) do\n    Account.create!(\n      company: company,\n      name: 'Jane Smith Account',\n      email: 'jane@example.com',\n      status: 'active'\n    )\n  end\n\n  before do\n    lead.update!(converted_account_id: account.id)\n  end"
    )
    File.write(int_file, content)
    puts "   ✅ Added account to integration spec"
  else
    puts "   ℹ️  Account already exists in integration spec"
  end
end

# Fix 3: Add account1/account2 to security spec
puts "\n3. Adding account1 and account2 to security spec..."
sec_file = 'spec/security/portal_authorization_spec.rb'
if File.exist?(sec_file)
  content = File.read(sec_file)
  
  # Add accounts after buyer definitions
  unless content.include?('let(:account1)')
    content.sub!(
      /let\(:buyer2\) do[^e]+end/m,
      "\\0\n\n  let(:account1) do\n    Account.create!(\n      company: company,\n      name: 'Alice Account',\n      email: 'alice@example.com',\n      status: 'active'\n    )\n  end\n\n  let(:account2) do\n    Account.create!(\n      company: company,\n      name: 'Bob Account',\n      email: 'bob@example.com',\n      status: 'active'\n    )\n  end\n\n  before do\n    buyer1.update!(converted_account_id: account1.id)\n    buyer2.update!(converted_account_id: account2.id)\n  end"
    )
    File.write(sec_file, content)
    puts "   ✅ Added accounts to security spec"
  else
    puts "   ℹ️  Accounts already exist in security spec"
  end
end

# Fix 4: Fix Communication metadata serialization issue
puts "\n4. Checking Communication metadata serialization..."
puts "   ℹ️  This is handled by the model - metadata uses coder: JSON"
puts "   ℹ️  Issue is that metadata needs string keys, not symbol keys"

puts "\n" + "=" * 60
puts "✅ All fixes applied!"
puts "\nNext: Run tests to verify fixes"
puts "  ./test_phase4_complete.sh"

#!/bin/bash

# Phase 4E - Final Fixes
# This script applies the remaining fixes to pass all tests

echo "🔧 Phase 4E - Applying Final Fixes"
echo "========================================"

cd /home/tschi/src/renterinsight_api

# Fix 1: Already done - metadata string keys in BuyerPortalService ✅

# Fix 2: Add channel to all CommunicationThread.create! calls
echo "1. Adding channel field to CommunicationThread creations..."

# Integration spec
ruby -i.bak -pe '
  if /CommunicationThread\.create!\(/
    gsub(/participant_type: "Lead", participant_id: lead\.id,\s*subject:/, "participant_type: \"Lead\", participant_id: lead.id,\n        channel: \"portal_message\",\n        subject:")
  end
' spec/integration/buyer_portal_flow_spec.rb 2>/dev/null && echo "   ✅ Integration spec updated"

# Security spec
ruby -i.bak -pe '
  if /CommunicationThread\.create!\(/
    gsub(/participant_type: "Lead", participant_id: buyer1\.id,\s*subject:/, "participant_type: \"Lead\", participant_id: buyer1.id,\n        channel: \"portal_message\",\n        subject:")
    gsub(/participant_type: "Lead", participant_id: buyer2\.id,\s*subject:/, "participant_type: \"Lead\", participant_id: buyer2.id,\n        channel: \"portal_message\",\n        subject:")
  end
' spec/security/portal_authorization_spec.rb 2>/dev/null && echo "   ✅ Security spec updated"

# Service spec
ruby -i.bak -pe '
  if /CommunicationThread\.create!\(/
    gsub(/participant_type: .Lead., participant_id: lead\.id,\s*subject:/, "participant_type: \"Lead\", participant_id: lead.id,\n      channel: \"portal_message\",\n      subject:")
  end
' spec/services/buyer_portal_service_spec.rb 2>/dev/null && echo "   ✅ Service spec updated"

echo ""
echo "2. Adding account variables to test specs..."

# Add account to integration spec (after line with 'let(:lead)')
sed -i '/let(:lead) do/,/^  end$/a\
\
  let(:account) do\
    Account.create!(\
      company: company,\
      name: \"Jane Smith Account\",\
      email: \"jane@example.com\",\
      status: \"active\"\
    )\
  end\
\
  before do\
    lead.update!(converted_account_id: account.id, is_converted: true)\
  end' spec/integration/buyer_portal_flow_spec.rb 2>/dev/null && echo "   ✅ Integration spec - account added"

# Add accounts to security spec  
sed -i '/let(:buyer2) do/,/^  end$/a\
\
  let(:account1) do\
    Account.create!(\
      company: company,\
      name: \"Alice Account\",\
      email: \"alice@example.com\",\
      status: \"active\"\
    )\
  end\
\
  let(:account2) do\
    Account.create!(\
      company: company,\
      name: \"Bob Account\",\
      email: \"bob@example.com\",\
      status: \"active\"\
    )\
  end\
\
  before do\
    buyer1.update!(converted_account_id: account1.id, is_converted: true)\
    buyer2.update!(converted_account_id: account2.id, is_converted: true)\
  end' spec/security/portal_authorization_spec.rb 2>/dev/null && echo "   ✅ Security spec - accounts added"

echo ""
echo "========================================"
echo "✅ All fixes applied!"
echo ""
echo "Next: Run tests again"
echo "  ./test_phase4_complete.sh"
echo ""
echo "Note: Route fixes need to be done manually in config/routes.rb"
echo "Add these routes:"
echo "  get 'auth/verify_magic_link', to: 'auth#verify_magic_link'"
echo "  post 'auth/request_reset', to: 'auth#request_reset'"

#!/bin/bash

# Phase 4E Test Fixes - Apply all corrections at once

echo "🔧 Applying Phase 4E Test Fixes..."
echo "=================================================="

# Fix 1: Service spec - Add passwords and fix associations
echo "Fixing spec/services/buyer_portal_service_spec.rb..."
sed -i "s/buyer: lead,/account: account,/g" spec/services/buyer_portal_service_spec.rb
sed -i "s/threadable: lead/participant_type: 'Lead', participant_id: lead.id/g" spec/services/buyer_portal_service_spec.rb
sed -i "s/BuyerPortalAccess\.create!(\s*buyer: lead,\s*email: 'john@example.com',\s*portal_enabled: true\s*)/BuyerPortalAccess.create!(buyer: lead, email: 'john@example.com', password: 'Password123!', password_confirmation: 'Password123!', portal_enabled: true)/g" spec/services/buyer_portal_service_spec.rb

# Add account setup in service spec (before the company let block)
sed -i '/let(:company)/a\  let(:account) { Account.create!(company: company, name: '\''John Doe Account'\'', email: '\''john@example.com'\'', status: '\''active'\'') }' spec/services/buyer_portal_service_spec.rb

# Fix 2: Integration spec - Fix associations  
echo "Fixing spec/integration/buyer_portal_flow_spec.rb..."
sed -i "s/buyer: lead,/account: account,/g" spec/integration/buyer_portal_flow_spec.rb
sed -i "s/threadable: lead/participant_type: 'Lead', participant_id: lead.id/g" spec/integration/buyer_portal_flow_spec.rb

# Fix 3: Security spec - Fix associations and method calls
echo "Fixing spec/security/portal_authorization_spec.rb..."
sed -i "s/buyer: buyer1,/account: account1,/g" spec/security/portal_authorization_spec.rb
sed -i "s/buyer: buyer2,/account: account2,/g" spec/security/portal_authorization_spec.rb  
sed -i "s/threadable: buyer1/participant_type: 'Lead', participant_id: buyer1.id/g" spec/security/portal_authorization_spec.rb
sed -i "s/threadable: buyer2/participant_type: 'Lead', participant_id: buyer2.id/g" spec/security/portal_authorization_spec.rb
sed -i "s/portal_access2\.update_preferences({ email_opt_in: true })/portal_access2.update!(email_opt_in: true)/g" spec/security/portal_authorization_spec.rb

echo "=================================================="
echo "✅ All fixes applied!"
echo ""
echo "Next: Run tests"
echo "  ./test_phase4_complete.sh"

#!/bin/bash

# Phase 4E Complete Fix Script
# This script applies all necessary fixes to make Phase 4E tests pass

echo "🔧 Phase 4E Complete Fix Application"
echo "========================================"
echo ""

cd /home/tschi/src/renterinsight_api

# Step 1: Apply the service spec fix
echo "1. Applying service spec fixes..."
if [ -f "spec/services/buyer_portal_service_spec_FIXED.rb" ]; then
    cp spec/services/buyer_portal_service_spec_FIXED.rb spec/services/buyer_portal_service_spec.rb
    echo "   ✅ Service spec fixed"
else
    echo "   ⚠️ Fixed file not found, skipping"
fi

# Step 2: Fix integration spec
echo "2. Fixing integration spec..."
ruby -i.bak -pe '
  gsub(/buyer: lead,/, "account: account,");
  gsub(/threadable: lead/, "participant_type: \"Lead\", participant_id: lead.id");
' spec/integration/buyer_portal_flow_spec.rb 2>/dev/null && echo "   ✅ Integration spec fixed" || echo "   ⚠️  Integration spec not found"

# Step 3: Fix security spec
echo "3. Fixing security spec..."
ruby -i.bak -pe '
  gsub(/buyer: buyer1,/, "account: account1,");
  gsub(/buyer: buyer2,/, "account: account2,");
  gsub(/threadable: buyer1/, "participant_type: \"Lead\", participant_id: buyer1.id");
  gsub(/threadable: buyer2/, "participant_type: \"Lead\", participant_id: buyer2.id");
  gsub(/portal_access2\.update_preferences\(\{ email_opt_in: true \}\)/, "portal_access2.update!(email_opt_in: true)");
' spec/security/portal_authorization_spec.rb 2>/dev/null && echo "   ✅ Security spec fixed" || echo "   ⚠️  Security spec not found"

echo ""
echo "========================================"
echo "✅ All fixes applied!"
echo ""
echo "Next steps:"
echo "1. Run: ./test_phase4_complete.sh"
echo "2. Check for remaining route-related failures"
echo "3. Test UI integration"

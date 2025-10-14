#!/bin/bash

echo "=========================================="
echo "Testing Phase 4E Fixes"
echo "=========================================="
echo ""

cd "$(dirname "$0")"

echo "=== Testing BuyerPortalService ==="
bundle exec rspec spec/services/buyer_portal_service_spec.rb
SERVICE_RESULT=$?

echo ""
echo "=== Testing Auth Controller ==="
bundle exec rspec spec/controllers/api/portal/auth_controller_spec.rb
AUTH_RESULT=$?

echo ""
echo "=== Testing Communications Controller (NEW) ==="
bundle exec rspec spec/controllers/api/portal/communications_controller_spec.rb
COMM_RESULT=$?

echo ""
echo "=== Testing Integration Flow ==="
bundle exec rspec spec/integration/buyer_portal_flow_spec.rb
INTEGRATION_RESULT=$?

echo ""
echo "=== Testing Security ==="
bundle exec rspec spec/security/portal_authorization_spec.rb
SECURITY_RESULT=$?

echo ""
echo "=== Testing All Portal Controllers ==="
bundle exec rspec spec/controllers/api/portal/
CONTROLLERS_RESULT=$?

echo ""
echo "=========================================="
echo "RESULTS SUMMARY"
echo "=========================================="
echo ""

[ $SERVICE_RESULT -eq 0 ] && echo "✅ BuyerPortalService: PASSED" || echo "❌ BuyerPortalService: FAILED"
[ $AUTH_RESULT -eq 0 ] && echo "✅ Auth Controller: PASSED" || echo "❌ Auth Controller: FAILED"
[ $COMM_RESULT -eq 0 ] && echo "✅ Communications Controller: PASSED" || echo "❌ Communications Controller: FAILED"
[ $INTEGRATION_RESULT -eq 0 ] && echo "✅ Integration Flow: PASSED" || echo "❌ Integration Flow: FAILED"
[ $SECURITY_RESULT -eq 0 ] && echo "✅ Security Tests: PASSED" || echo "❌ Security Tests: FAILED"
[ $CONTROLLERS_RESULT -eq 0 ] && echo "✅ All Controllers: PASSED" || echo "❌ All Controllers: FAILED"

echo ""

# Calculate overall result
TOTAL_FAILURES=$((SERVICE_RESULT + AUTH_RESULT + COMM_RESULT + INTEGRATION_RESULT + SECURITY_RESULT + CONTROLLERS_RESULT))

if [ $TOTAL_FAILURES -eq 0 ]; then
    echo "🎉 ALL TESTS PASSED! Phase 4E Complete!"
    exit 0
else
    echo "⚠️  Some tests failed. Review output above."
    exit 1
fi

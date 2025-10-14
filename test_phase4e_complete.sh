#!/bin/bash
cd ~/src/renterinsight_api

echo "=========================================="
echo "🧪 PHASE 4E - COMPLETE TEST SUITE"
echo "=========================================="
echo ""

# Track results
PASSED=0
FAILED=0

run_test() {
    local name=$1
    local spec=$2
    
    echo "=== Testing: $name ==="
    if bundle exec rspec "$spec" --format progress; then
        echo "✅ $name PASSED"
        ((PASSED++))
    else
        echo "❌ $name FAILED"
        ((FAILED++))
    fi
    echo ""
}

# Run all Phase 4E tests
run_test "BuyerPortalAccess Model" "spec/models/buyer_portal_access_spec.rb"
run_test "BuyerPortalService" "spec/services/buyer_portal_service_spec.rb"
run_test "Auth Controller" "spec/controllers/api/portal/auth_controller_spec.rb"
run_test "Quotes Controller" "spec/controllers/api/portal/quotes_controller_spec.rb"
run_test "Documents Controller" "spec/controllers/api/portal/documents_controller_spec.rb"
run_test "Preferences Controller" "spec/controllers/api/portal/preferences_controller_spec.rb"
run_test "Communications Controller" "spec/controllers/api/portal/communications_controller_spec.rb"

echo "=========================================="
echo "📊 RESULTS SUMMARY"
echo "=========================================="
echo "✅ Passed: $PASSED"
echo "❌ Failed: $FAILED"
echo ""

if [ $FAILED -eq 0 ]; then
    echo "🎉 ALL PHASE 4E TESTS PASSED!"
    echo ""
    echo "Phase 4E is COMPLETE! ✨"
    exit 0
else
    echo "⚠️  Some tests failed. Review output above."
    exit 1
fi

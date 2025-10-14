#!/bin/bash

# Phase 4E Complete Test Suite
# Tests all buyer portal functionality including integration and security

echo "🧪 PHASE 4E - BUYER PORTAL COMPLETE TEST SUITE"
echo "=============================================="
echo ""

# Color codes
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counter
total_tests=0
passed_tests=0
failed_tests=0

# Function to run a test suite
run_test_suite() {
    local test_file=$1
    local test_name=$2
    
    echo -e "${BLUE}Running: $test_name${NC}"
    echo "----------------------------------------"
    
    if bundle exec rspec "$test_file" --format documentation; then
        echo -e "${GREEN}✅ $test_name PASSED${NC}"
        ((passed_tests++))
    else
        echo -e "${RED}❌ $test_name FAILED${NC}"
        ((failed_tests++))
    fi
    
    ((total_tests++))
    echo ""
}

# Start testing
echo "Starting comprehensive test suite..."
echo ""

# Phase 4D Tests (Prerequisites)
echo -e "${YELLOW}=== PHASE 4D: PREREQUISITES ===${NC}"
run_test_suite "spec/models/buyer_portal_access_spec.rb" "Buyer Portal Access Model"
run_test_suite "spec/controllers/api/portal/preferences_controller_spec.rb" "Preferences Controller"

# Phase 4E Service Tests
echo -e "${YELLOW}=== PHASE 4E: SERVICE LAYER ===${NC}"
run_test_suite "spec/services/buyer_portal_service_spec.rb" "Buyer Portal Service"

# Phase 4E Integration Tests
echo -e "${YELLOW}=== PHASE 4E: INTEGRATION TESTS ===${NC}"
run_test_suite "spec/integration/buyer_portal_flow_spec.rb" "Complete Portal Flow"

# Phase 4E Security Tests
echo -e "${YELLOW}=== PHASE 4E: SECURITY TESTS ===${NC}"
run_test_suite "spec/security/portal_authorization_spec.rb" "Portal Authorization & Isolation"

# Other Portal Controllers
echo -e "${YELLOW}=== PHASE 4E: API CONTROLLERS ===${NC}"
run_test_suite "spec/controllers/api/portal/auth_controller_spec.rb" "Authentication Controller"
run_test_suite "spec/controllers/api/portal/communications_controller_spec.rb" "Communications Controller"
run_test_suite "spec/controllers/api/portal/quotes_controller_spec.rb" "Quotes Controller"

# Summary
echo ""
echo "=============================================="
echo -e "${BLUE}TEST SUMMARY${NC}"
echo "=============================================="
echo -e "Total Test Suites: $total_tests"
echo -e "${GREEN}Passed: $passed_tests${NC}"
if [ $failed_tests -gt 0 ]; then
    echo -e "${RED}Failed: $failed_tests${NC}"
else
    echo -e "Failed: $failed_tests"
fi
echo ""

# Final result
if [ $failed_tests -eq 0 ]; then
    echo -e "${GREEN}🎉 ALL TESTS PASSED! Phase 4E Complete! 🎉${NC}"
    echo ""
    echo "The Buyer Portal Backend is fully functional and tested:"
    echo "  ✅ Authentication & Authorization"
    echo "  ✅ Communications Management"
    echo "  ✅ Quote Management"
    echo "  ✅ Preference Management"
    echo "  ✅ Email Integration"
    echo "  ✅ Security & Data Isolation"
    echo ""
    exit 0
else
    echo -e "${RED}❌ Some tests failed. Please review the errors above.${NC}"
    echo ""
    exit 1
fi

#!/bin/bash
# Quick SMS MFA Backend Test

echo "=========================================="
echo "🧪 SMS MFA Backend Quick Test"
echo "=========================================="
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

PASSED=0
FAILED=0

# Helper function
run_test() {
    local test_name="$1"
    local test_command="$2"
    
    echo -n "Testing: $test_name... "
    
    if eval "$test_command" >/dev/null 2>&1; then
        echo -e "${GREEN}✅ PASSED${NC}"
        ((PASSED++))
    else
        echo -e "${RED}❌ FAILED${NC}"
        ((FAILED++))
    fi
}

echo "1️⃣  MIGRATION CHECK"
echo "-------------------"
run_test "phone_verified column" \
    "bundle exec rails runner 'exit(User.first.respond_to?(:phone_verified) ? 0 : 1)'"
run_test "mfa_sms_code column" \
    "bundle exec rails runner 'exit(User.first.respond_to?(:mfa_sms_code) ? 0 : 1)'"
run_test "mfa_method column" \
    "bundle exec rails runner 'exit(User.first.respond_to?(:mfa_method) ? 0 : 1)'"
run_test "TOTP columns preserved" \
    "bundle exec rails runner 'exit(User.first.respond_to?(:mfa_secret) ? 0 : 1)'"
echo ""

echo "2️⃣  SERVICE CHECK"
echo "----------------"
run_test "Mfa::SmsService exists" \
    "bundle exec rails runner 'Mfa::SmsService.new(User.first); exit(0)'"
run_test "Service has send_code" \
    "bundle exec rails runner 'exit(Mfa::SmsService.new(User.first).respond_to?(:send_code) ? 0 : 1)'"
run_test "Service has verify" \
    "bundle exec rails runner 'exit(Mfa::SmsService.new(User.first).respond_to?(:verify) ? 0 : 1)'"
echo ""

echo "3️⃣  ROUTES CHECK"
echo "----------------"
run_test "SMS enroll route exists" \
    "bundle exec rails routes | grep -q 'mfa/sms/enroll'"
run_test "TOTP routes preserved" \
    "bundle exec rails routes | grep 'mfa/enroll' | grep -q -v sms"
echo ""

echo "=========================================="
echo -e "RESULTS: ${GREEN}${PASSED} passed${NC}, ${RED}${FAILED} failed${NC}"
echo "=========================================="

if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ Backend ready! Run API tests next.${NC}"
    exit 0
else
    echo -e "${RED}❌ Issues found. Check migration status.${NC}"
    exit 1
fi

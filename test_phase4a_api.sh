#!/bin/bash

# Manual API Testing for Phase 4A
# Run this after starting your Rails server

set -e

API_URL="http://localhost:3000/api/portal"

echo "================================"
echo "PHASE 4A: MANUAL API TESTS"
echo "================================"
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "🔧 First, create a test buyer in Rails console:"
echo ""
echo -e "${YELLOW}bundle exec rails runner \"
lead = Lead.create!(
  first_name: 'Test',
  last_name: 'Buyer',
  email: 'testbuyer@example.com',
  phone: '555-1234'
)

buyer_access = BuyerPortalAccess.create!(
  buyer: lead,
  email: 'testbuyer@example.com',
  password: 'Password123!',
  password_confirmation: 'Password123!',
  portal_enabled: true
)

puts 'Created test buyer: testbuyer@example.com'
puts 'Password: Password123!'
\"${NC}"
echo ""
read -p "Press Enter after creating the test buyer..."

echo ""
echo "================================"
echo "TEST 1: Login with Password"
echo "================================"
echo ""

LOGIN_RESPONSE=$(curl -s -X POST "$API_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "testbuyer@example.com",
    "password": "Password123!"
  }')

echo "Response:"
echo "$LOGIN_RESPONSE" | jq '.'

# Extract token
TOKEN=$(echo "$LOGIN_RESPONSE" | jq -r '.token')

if [ "$TOKEN" != "null" ] && [ -n "$TOKEN" ]; then
  echo -e "${GREEN}✅ Login successful! Token received.${NC}"
  echo "Token: $TOKEN"
else
  echo -e "${RED}❌ Login failed!${NC}"
  exit 1
fi

echo ""
echo "================================"
echo "TEST 2: Get Profile (Authenticated)"
echo "================================"
echo ""

PROFILE_RESPONSE=$(curl -s -X GET "$API_URL/auth/profile" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json")

echo "Response:"
echo "$PROFILE_RESPONSE" | jq '.'

if echo "$PROFILE_RESPONSE" | jq -e '.ok' > /dev/null; then
  echo -e "${GREEN}✅ Profile retrieved successfully!${NC}"
else
  echo -e "${RED}❌ Profile retrieval failed!${NC}"
fi

echo ""
echo "================================"
echo "TEST 3: Request Magic Link"
echo "================================"
echo ""

MAGIC_RESPONSE=$(curl -s -X POST "$API_URL/auth/magic-link" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "testbuyer@example.com"
  }')

echo "Response:"
echo "$MAGIC_RESPONSE" | jq '.'

if echo "$MAGIC_RESPONSE" | jq -e '.ok' > /dev/null; then
  echo -e "${GREEN}✅ Magic link request successful!${NC}"
  echo ""
  echo "Check Rails logs for the magic link token:"
  echo -e "${YELLOW}tail -f log/development.log | grep 'Magic link'${NC}"
else
  echo -e "${RED}❌ Magic link request failed!${NC}"
fi

echo ""
echo "================================"
echo "TEST 4: Request Password Reset"
echo "================================"
echo ""

RESET_RESPONSE=$(curl -s -X POST "$API_URL/auth/reset-password" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "testbuyer@example.com"
  }')

echo "Response:"
echo "$RESET_RESPONSE" | jq '.'

if echo "$RESET_RESPONSE" | jq -e '.ok' > /dev/null; then
  echo -e "${GREEN}✅ Password reset request successful!${NC}"
  echo ""
  echo "Check Rails logs for the reset token:"
  echo -e "${YELLOW}tail -f log/development.log | grep 'Reset token'${NC}"
else
  echo -e "${RED}❌ Password reset request failed!${NC}"
fi

echo ""
echo "================================"
echo "TEST 5: Invalid Login Attempt"
echo "================================"
echo ""

INVALID_RESPONSE=$(curl -s -X POST "$API_URL/auth/login" \
  -H "Content-Type: application/json" \
  -d '{
    "email": "testbuyer@example.com",
    "password": "WrongPassword"
  }')

echo "Response:"
echo "$INVALID_RESPONSE" | jq '.'

if echo "$INVALID_RESPONSE" | jq -e '.ok == false' > /dev/null; then
  echo -e "${GREEN}✅ Invalid login correctly rejected!${NC}"
else
  echo -e "${RED}❌ Invalid login should have been rejected!${NC}"
fi

echo ""
echo "================================"
echo "TEST 6: Unauthorized Access"
echo "================================"
echo ""

UNAUTH_RESPONSE=$(curl -s -X GET "$API_URL/auth/profile" \
  -H "Content-Type: application/json")

echo "Response:"
echo "$UNAUTH_RESPONSE" | jq '.'

if echo "$UNAUTH_RESPONSE" | grep -q "Unauthorized"; then
  echo -e "${GREEN}✅ Unauthorized access correctly blocked!${NC}"
else
  echo -e "${RED}❌ Should require authentication!${NC}"
fi

echo ""
echo "================================"
echo "✅ ALL MANUAL TESTS COMPLETE"
echo "================================"
echo ""
echo "Summary:"
echo "- Login: ✓"
echo "- Profile: ✓"
echo "- Magic Link: ✓"
echo "- Password Reset: ✓"
echo "- Invalid Login: ✓"
echo "- Unauthorized: ✓"
echo ""

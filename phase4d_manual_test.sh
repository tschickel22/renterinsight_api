#!/bin/bash
# Phase 4D Manual API Test Script
# This script helps you manually test the preferences API

echo "=========================================="
echo "🧪 Phase 4D Manual API Testing"
echo "=========================================="
echo ""

# Check if server is running
echo "Checking if Rails server is running on port 3001..."
if curl -s http://localhost:3001/health > /dev/null 2>&1; then
    echo "✅ Server is running"
else
    echo "❌ Server is not running!"
    echo "Please start it with: rails s -p 3001"
    exit 1
fi

echo ""
echo "Creating test user and getting JWT token..."
echo ""

# Create test data
ruby create_test_preferences.rb > /tmp/test_output.txt 2>&1

# Extract token
TOKEN=$(grep "JWT Token:" /tmp/test_output.txt | cut -d: -f2- | tr -d ' ')
EMAIL=$(grep "Email:" /tmp/test_output.txt | cut -d: -f2- | tr -d ' ')

if [ -z "$TOKEN" ]; then
    echo "❌ Failed to get JWT token"
    cat /tmp/test_output.txt
    exit 1
fi

echo "✅ Test user created: $EMAIL"
echo "✅ JWT token obtained"
echo ""

echo "=========================================="
echo "Test 1: View Current Preferences"
echo "=========================================="
echo ""
echo "Request:"
echo "GET http://localhost:3001/api/portal/preferences"
echo ""

curl -X GET http://localhost:3001/api/portal/preferences \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -w "\nStatus: %{http_code}\n" \
  2>/dev/null | jq '.'

echo ""
echo "Press Enter to continue..."
read

echo ""
echo "=========================================="
echo "Test 2: Update Email Preference"
echo "=========================================="
echo ""
echo "Request:"
echo "PATCH http://localhost:3001/api/portal/preferences"
echo "Body: {\"preferences\": {\"email_opt_in\": false}}"
echo ""

curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"preferences": {"email_opt_in": false}}' \
  -w "\nStatus: %{http_code}\n" \
  2>/dev/null | jq '.'

echo ""
echo "Press Enter to continue..."
read

echo ""
echo "=========================================="
echo "Test 3: Update Multiple Preferences"
echo "=========================================="
echo ""
echo "Request:"
echo "PATCH http://localhost:3001/api/portal/preferences"
echo "Body: {\"preferences\": {\"email_opt_in\": true, \"sms_opt_in\": true, \"marketing_opt_in\": false}}"
echo ""

curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"preferences": {"email_opt_in": true, "sms_opt_in": true, "marketing_opt_in": false}}' \
  -w "\nStatus: %{http_code}\n" \
  2>/dev/null | jq '.'

echo ""
echo "Press Enter to continue..."
read

echo ""
echo "=========================================="
echo "Test 4: View Preference History"
echo "=========================================="
echo ""
echo "Request:"
echo "GET http://localhost:3001/api/portal/preferences/history"
echo ""

curl -X GET http://localhost:3001/api/portal/preferences/history \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -w "\nStatus: %{http_code}\n" \
  2>/dev/null | jq '.'

echo ""
echo "Press Enter to continue..."
read

echo ""
echo "=========================================="
echo "Test 5: Security Test (Try to disable portal)"
echo "=========================================="
echo ""
echo "Request:"
echo "PATCH http://localhost:3001/api/portal/preferences"
echo "Body: {\"preferences\": {\"portal_enabled\": false}}"
echo "Expected: 403 Forbidden"
echo ""

curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"preferences": {"portal_enabled": false}}' \
  -w "\nStatus: %{http_code}\n" \
  2>/dev/null | jq '.'

echo ""
echo "Press Enter to continue..."
read

echo ""
echo "=========================================="
echo "Test 6: Validation Test (Invalid value)"
echo "=========================================="
echo ""
echo "Request:"
echo "PATCH http://localhost:3001/api/portal/preferences"
echo "Body: {\"preferences\": {\"email_opt_in\": \"yes\"}}"
echo "Expected: 422 Unprocessable Entity"
echo ""

curl -X PATCH http://localhost:3001/api/portal/preferences \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"preferences": {"email_opt_in": "yes"}}' \
  -w "\nStatus: %{http_code}\n" \
  2>/dev/null | jq '.'

echo ""
echo "Press Enter to continue..."
read

echo ""
echo "=========================================="
echo "Test 7: Authentication Test (No token)"
echo "=========================================="
echo ""
echo "Request:"
echo "GET http://localhost:3001/api/portal/preferences"
echo "Expected: 401 Unauthorized"
echo ""

curl -X GET http://localhost:3001/api/portal/preferences \
  -H "Content-Type: application/json" \
  -w "\nStatus: %{http_code}\n" \
  2>/dev/null | jq '.'

echo ""
echo ""
echo "=========================================="
echo "✅ All Manual Tests Complete!"
echo "=========================================="
echo ""
echo "Results Summary:"
echo "1. ✅ View preferences - Should return current preferences"
echo "2. ✅ Update single preference - Should update and track change"
echo "3. ✅ Update multiple preferences - Should update all and track"
echo "4. ✅ View history - Should show all tracked changes"
echo "5. ✅ Security test - Should deny portal_enabled update (403)"
echo "6. ✅ Validation test - Should reject invalid values (422)"
echo "7. ✅ Authentication test - Should require JWT token (401)"
echo ""
echo "Your JWT token (valid 24 hours):"
echo "$TOKEN"
echo ""
echo "Save this for additional testing!"
echo ""

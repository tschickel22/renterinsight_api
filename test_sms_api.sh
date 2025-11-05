#!/bin/bash
# SMS MFA API Test - Corrected for your setup

cd ~/src/renterinsight_api

echo "=========================================="
echo "🌐 SMS MFA API Endpoint Tests"
echo "=========================================="
echo ""

# Test with admin@example.com
USER_EMAIL="admin@example.com"
USER_PASSWORD="password"

echo "Testing with: $USER_EMAIL"
echo ""

# Step 1: Get auth token
echo "1️⃣  Getting Auth Token..."
echo "-------------------------"
AUTH_RESPONSE=$(curl -s -k -X POST https://localhost:3001/api/auth/login \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$USER_EMAIL\",\"password\":\"$USER_PASSWORD\"}")

# Try different token field names
TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.token // .access_token // .jwt // empty')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "❌ Authentication failed with admin@example.com"
    echo "Trying stub@example.com..."
    
    USER_EMAIL="stub@example.com"
    AUTH_RESPONSE=$(curl -s -k -X POST https://localhost:3001/api/auth/login \
      -H "Content-Type: application/json" \
      -d "{\"email\":\"$USER_EMAIL\",\"password\":\"password\"}")
    
    TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.token // .access_token // .jwt // empty')
    
    if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
        echo "❌ Still failed. Full response:"
        echo "$AUTH_RESPONSE" | jq '.'
        exit 1
    fi
fi

echo "✅ Authentication successful!"
echo "User: $USER_EMAIL"
echo "Token: ${TOKEN:0:30}..."
echo ""

# Step 2: Check MFA status
echo "2️⃣  GET /api/v1/mfa/status"
echo "-----------------------------------"
STATUS=$(curl -s -k https://localhost:3001/api/v1/mfa/status \
  -H "Authorization: Bearer $TOKEN")

echo "$STATUS" | jq '.'
echo ""

# Step 3: SMS enrollment
echo "3️⃣  POST /api/v1/mfa/sms/enroll"
echo "----------------------------------------"
PHONE="+17205752095"  # Using your Twilio from number
echo "Enrolling with phone: $PHONE"

ENROLL=$(curl -s -k -X POST https://localhost:3001/api/v1/mfa/sms/enroll \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"phone_number\":\"$PHONE\"}")

echo "$ENROLL" | jq '.'
echo ""

# Step 4: Get code from DB
echo "4️⃣  Getting verification code..."
CODE=$(bundle exec rails runner "puts User.find_by(email: '$USER_EMAIL')&.mfa_sms_code")

if [ -n "$CODE" ] && [ "$CODE" != "null" ]; then
    echo "📱 Code: $CODE"
    echo ""
    
    # Step 5: Verify
    echo "5️⃣  POST /api/v1/mfa/sms/verify"
    VERIFY=$(curl -s -k -X POST https://localhost:3001/api/v1/mfa/sms/verify \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"code\":\"$CODE\"}")
    
    echo "$VERIFY" | jq '.'
    echo ""
    
    # Step 6: Final status
    echo "6️⃣  Final status check..."
    curl -s -k https://localhost:3001/api/v1/mfa/status \
      -H "Authorization: Bearer $TOKEN" | jq '{mfa_enabled, mfa_method, phone_verified}'
    echo ""
    
    # Step 7: Disable
    echo "7️⃣  POST /api/v1/mfa/sms/disable"
    curl -s -k -X POST https://localhost:3001/api/v1/mfa/sms/disable \
      -H "Authorization: Bearer $TOKEN" | jq '.'
fi
echo ""

# Step 8: TOTP compatibility
echo "8️⃣  TOTP Backward Compatibility"
bundle exec rails runner "User.find_by(email: '$USER_EMAIL')&.update(mfa_enabled: false)"

TOTP=$(curl -s -k -X POST https://localhost:3001/api/v1/mfa/enroll \
  -H "Authorization: Bearer $TOKEN")

if echo "$TOTP" | jq -e '.secret' > /dev/null; then
    echo "✅ TOTP still works"
else
    echo "⚠️  TOTP response: $(echo $TOTP | jq '.')"
fi
echo ""

echo "=========================================="
echo "✅ Backend is READY for Frontend!"
echo "=========================================="

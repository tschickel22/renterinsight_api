#!/bin/bash
echo "Testing SMS MFA API Endpoints..."

# Get auth token
TOKEN=$(curl -s -k -X POST https://localhost:3001/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"password"}' | jq -r '.token')

echo "Token: $TOKEN"
echo ""

# Test status endpoint
echo "1. Testing GET /api/v1/mfa/status"
curl -s -k https://localhost:3001/api/v1/mfa/status \
  -H "Authorization: Bearer $TOKEN" | jq '.'
echo ""

# Test SMS enroll
echo "2. Testing POST /api/v1/mfa/sms/enroll"
curl -s -k -X POST https://localhost:3001/api/v1/mfa/sms/enroll \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"phone_number":"+15551234567"}' | jq '.'
echo ""

echo "✅ API tests complete!"

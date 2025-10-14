#!/bin/bash

# Test creating a quote with camelCase parameters (like frontend sends)

BASE_URL="http://localhost:3001/api/v1"

echo "========================================="
echo "Testing Quote Creation with camelCase"
echo "========================================="
echo ""

echo "Creating quote with camelCase parameters..."
curl -X POST "${BASE_URL}/quotes" \
  -H "Content-Type: application/json" \
  -d '{
    "quote": {
      "accountId": "11",
      "contactId": "2",
      "customerId": "11",
      "items": [
        {
          "id": "1",
          "description": "Test Product",
          "quantity": 2,
          "unitPrice": 100.00,
          "total": 200.00
        }
      ],
      "subtotal": 200.00,
      "tax": 20.00,
      "total": 220.00,
      "status": "draft",
      "validUntil": "2025-11-11",
      "notes": "Test quote from API",
      "customFields": {}
    }
  }' | jq .

echo ""
echo "========================================="
echo "Test Complete!"
echo "========================================="

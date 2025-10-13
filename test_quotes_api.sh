#!/bin/bash

# Test Quotes API
BASE_URL="http://localhost:3001/api/v1"

echo "========================================="
echo "Testing Quotes API Endpoints"
echo "========================================="
echo ""

# Test 1: Get all quotes (should return empty array initially)
echo "1. GET /api/v1/quotes (Get all quotes)"
curl -s -X GET "${BASE_URL}/quotes" \
  -H "Content-Type: application/json" | jq .
echo ""
echo ""

# Test 2: Create a new quote
echo "2. POST /api/v1/quotes (Create new quote)"
QUOTE_RESPONSE=$(curl -s -X POST "${BASE_URL}/quotes" \
  -H "Content-Type: application/json" \
  -d '{
    "quote": {
      "account_id": 11,
      "status": "draft",
      "items": [
        {
          "id": "1",
          "description": "Product A",
          "quantity": 2,
          "unitPrice": 100.00,
          "total": 200.00
        },
        {
          "id": "2",
          "description": "Product B",
          "quantity": 1,
          "unitPrice": 50.00,
          "total": 50.00
        }
      ],
      "tax": 25.00,
      "notes": "Test quote from API",
      "valid_until": "2025-11-12"
    }
  }')

echo "$QUOTE_RESPONSE" | jq .
QUOTE_ID=$(echo "$QUOTE_RESPONSE" | jq -r '.id')
echo ""
echo "Created quote with ID: $QUOTE_ID"
echo ""

# Test 3: Get the created quote
if [ "$QUOTE_ID" != "null" ] && [ -n "$QUOTE_ID" ]; then
  echo "3. GET /api/v1/quotes/$QUOTE_ID (Get specific quote)"
  curl -s -X GET "${BASE_URL}/quotes/${QUOTE_ID}" \
    -H "Content-Type: application/json" | jq .
  echo ""
  echo ""

  # Test 4: Update the quote
  echo "4. PATCH /api/v1/quotes/$QUOTE_ID (Update quote)"
  curl -s -X PATCH "${BASE_URL}/quotes/${QUOTE_ID}" \
    -H "Content-Type: application/json" \
    -d '{
      "quote": {
        "notes": "Updated test quote"
      }
    }' | jq .
  echo ""
  echo ""

  # Test 5: Get quote stats
  echo "5. GET /api/v1/quotes/stats (Get statistics)"
  curl -s -X GET "${BASE_URL}/quotes/stats" \
    -H "Content-Type: application/json" | jq .
  echo ""
  echo ""

  # Test 6: Send the quote
  echo "6. POST /api/v1/quotes/$QUOTE_ID/send (Send quote)"
  curl -s -X POST "${BASE_URL}/quotes/${QUOTE_ID}/send" \
    -H "Content-Type: application/json" | jq .
  echo ""
  echo ""

  # Test 7: Get all quotes again
  echo "7. GET /api/v1/quotes (Get all quotes - should show 1)"
  curl -s -X GET "${BASE_URL}/quotes" \
    -H "Content-Type: application/json" | jq .
  echo ""
  echo ""
fi

echo "========================================="
echo "Quotes API Testing Complete"
echo "========================================="

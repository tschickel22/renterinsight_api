#!/bin/bash

# Test script for Contacts API endpoints
# Run this from the Rails API directory

BASE_URL="http://localhost:3000/api/v1"

echo "========================================="
echo "Testing Contacts API Endpoints"
echo "========================================="
echo ""

echo "1. Testing GET /contacts (List all contacts)"
echo "-----------------------------------------"
curl -s -X GET "$BASE_URL/contacts" | jq '.' || echo "Failed"
echo ""
echo ""

echo "2. Testing GET /contacts/stats (Statistics)"
echo "-----------------------------------------"
curl -s -X GET "$BASE_URL/contacts/stats" | jq '.' || echo "Failed"
echo ""
echo ""

echo "3. Testing POST /contacts (Create contact)"
echo "-----------------------------------------"
CONTACT_DATA='{
  "contact": {
    "account_id": 1,
    "first_name": "Test",
    "last_name": "Contact",
    "email": "test.contact@example.com",
    "phone": "555-0123",
    "title": "Manager",
    "department": "Sales",
    "notes": "Test contact created by API test script"
  }
}'
RESPONSE=$(curl -s -X POST "$BASE_URL/contacts" \
  -H "Content-Type: application/json" \
  -d "$CONTACT_DATA")
echo "$RESPONSE" | jq '.'
CONTACT_ID=$(echo "$RESPONSE" | jq -r '.id')
echo ""
echo "Created contact ID: $CONTACT_ID"
echo ""

if [ ! -z "$CONTACT_ID" ] && [ "$CONTACT_ID" != "null" ]; then
  echo "4. Testing GET /contacts/:id (Get single contact)"
  echo "-----------------------------------------"
  curl -s -X GET "$BASE_URL/contacts/$CONTACT_ID" | jq '.'
  echo ""
  echo ""

  echo "5. Testing PATCH /contacts/:id (Update contact)"
  echo "-----------------------------------------"
  UPDATE_DATA='{
    "contact": {
      "title": "Senior Manager",
      "notes": "Updated by test script"
    }
  }'
  curl -s -X PATCH "$BASE_URL/contacts/$CONTACT_ID" \
    -H "Content-Type: application/json" \
    -d "$UPDATE_DATA" | jq '.'
  echo ""
  echo ""

  echo "6. Testing POST /contacts/:id/tags (Add tags)"
  echo "-----------------------------------------"
  TAG_DATA='{"tags": ["VIP", "Test"]}'
  curl -s -X POST "$BASE_URL/contacts/$CONTACT_ID/tags" \
    -H "Content-Type: application/json" \
    -d "$TAG_DATA" | jq '.'
  echo ""
  echo ""

  echo "7. Testing DELETE /contacts/:id/tags/:tag_name (Remove tag)"
  echo "-----------------------------------------"
  curl -s -X DELETE "$BASE_URL/contacts/$CONTACT_ID/tags/Test" \
    -H "Content-Type: application/json" | jq '.'
  echo ""
  echo ""

  echo "8. Testing DELETE /contacts/:id (Delete contact)"
  echo "-----------------------------------------"
  curl -s -X DELETE "$BASE_URL/contacts/$CONTACT_ID" \
    -H "Content-Type: application/json"
  echo "Contact deleted (no content expected)"
  echo ""
  echo ""
fi

echo "9. Testing GET /contacts with filters"
echo "-----------------------------------------"
curl -s -X GET "$BASE_URL/contacts?department=Sales&sort_by=name" | jq '.' || echo "Failed"
echo ""
echo ""

echo "10. Testing GET /accounts/:account_id/contacts (Nested route)"
echo "-----------------------------------------"
curl -s -X GET "$BASE_URL/accounts/1/contacts" | jq '.' || echo "Failed"
echo ""
echo ""

echo "========================================="
echo "Tests Complete!"
echo "========================================="

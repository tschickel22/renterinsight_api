#!/bin/bash
# Quick test of the insights endpoint

echo "Testing AI Insights Endpoint..."
echo ""

# Test insights endpoint
echo "1. Testing /api/v1/accounts/11/insights"
curl -s http://localhost:3001/api/v1/accounts/11/insights | jq '.' 2>/dev/null || echo "Note: Install jq for formatted output"

echo ""
echo "2. Testing /api/v1/accounts/11/score"
curl -s http://localhost:3001/api/v1/accounts/11/score | jq '.' 2>/dev/null || echo "Note: Install jq for formatted output"

echo ""
echo "3. Testing /api/v1/accounts/11/messages"
curl -s http://localhost:3001/api/v1/accounts/11/messages | jq '.' 2>/dev/null || echo "Note: Install jq for formatted output"

echo ""
echo "If you see JSON responses above, the endpoints are working!"
echo ""
echo "Now test in the UI:"
echo "1. Go to an account page"
echo "2. Click 'AI Insights' tab"
echo "3. Should see engagement metrics and insights!"

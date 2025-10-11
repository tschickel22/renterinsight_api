#!/bin/bash
echo "Checking Rails routes..."
cd ~/src/renterinsight_api

echo "=== Account Routes ==="
bundle exec rails routes | grep account

echo ""
echo "=== V1 Routes ==="
bundle exec rails routes | grep v1

echo ""
echo "=== Testing Account Endpoints ==="
# Test listing accounts (this might fail)
echo "GET /api/v1/accounts:"
curl -s http://localhost:3001/api/v1/accounts | head -c 100
echo ""

# Test getting a single account (this should work)
echo "GET /api/v1/accounts/5:"
curl -s http://localhost:3001/api/v1/accounts/5 | head -c 200
echo ""

#!/bin/bash

# Phase 4A Test Runner
# Tests the authentication foundation for the Buyer Portal

set -e

echo "================================"
echo "PHASE 4A: AUTHENTICATION TESTS"
echo "================================"
echo ""

# Navigate to the Rails app directory
cd /home/tschi/src/renterinsight_api

echo "📦 Installing dependencies..."
bundle install --quiet

echo ""
echo "🗄️  Running migrations..."
RAILS_ENV=test bundle exec rails db:migrate

echo ""
echo "🧪 Running Phase 4A Tests..."
echo ""

# Run tests with detailed output
echo "1️⃣  Testing JsonWebToken helper..."
bundle exec rspec spec/lib/json_web_token_spec.rb --format documentation

echo ""
echo "2️⃣  Testing BuyerPortalAccess model..."
bundle exec rspec spec/models/buyer_portal_access_spec.rb --format documentation

echo ""
echo "3️⃣  Testing Portal Auth Controller..."
bundle exec rspec spec/controllers/api/portal/auth_controller_spec.rb --format documentation

echo ""
echo "================================"
echo "✅ ALL PHASE 4A TESTS COMPLETE"
echo "================================"
echo ""

# Run a quick sanity check
echo "🔍 Quick sanity checks..."
echo ""

echo "Checking if BuyerPortalAccess model exists..."
bundle exec rails runner "puts BuyerPortalAccess.new.class.name"

echo "Checking if JsonWebToken is available..."
bundle exec rails runner "puts JsonWebToken.class.name"

echo "Checking routes..."
bundle exec rails routes | grep "portal/auth"

echo ""
echo "================================"
echo "🎉 Phase 4A is ready to test!"
echo "================================"
echo ""
echo "Next steps:"
echo "1. Test login endpoint: POST /api/portal/auth/login"
echo "2. Test magic link: POST /api/portal/auth/magic-link"
echo "3. Test password reset flow"
echo ""

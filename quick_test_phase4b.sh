#!/bin/bash
# Phase 4B Quick Test - One command to test everything

set -e

echo "🚀 Phase 4B Quick Test"
echo "====================="
echo ""

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

cd ~/src/renterinsight_api

echo "1️⃣  Verifying implementation..."
bundle exec rails runner verify_phase4b.rb
echo ""

echo "2️⃣  Creating test data..."
bundle exec rails runner create_test_quotes.rb
echo ""

echo "3️⃣  Running tests..."
bundle exec rspec spec/services/quote_presenter_spec.rb spec/controllers/api/portal/quotes_controller_spec.rb --format progress
echo ""

echo -e "${GREEN}✅ Phase 4B verification complete!${NC}"
echo ""
echo "📋 Next steps:"
echo "   1. Start server: bin/rails s -p 3001"
echo "   2. Test endpoints: see PHASE4B_SETUP.md for curl examples"
echo "   3. Or proceed to Phase 4C"

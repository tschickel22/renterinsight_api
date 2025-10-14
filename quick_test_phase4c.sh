#!/bin/bash
# Quick test script for Phase 4C - Document Management

echo "🚀 Phase 4C - Document Management Quick Test"
echo "=============================================="
echo ""

cd ~/src/renterinsight_api

echo "📝 Step 1: Running migrations..."
RAILS_ENV=development bin/rails db:migrate

echo ""
echo "📝 Step 2: Running tests..."
bundle exec rspec spec/controllers/api/portal/documents_controller_spec.rb spec/models/portal_document_spec.rb --format documentation

echo ""
echo "📝 Step 3: Creating test data..."
bin/rails runner create_test_documents.rb

echo ""
echo "✅ Phase 4C Quick Test Complete!"
echo ""
echo "Next steps:"
echo "1. Test the API endpoints using the curl commands printed above"
echo "2. Check test results for any failures"
echo "3. If all tests pass, Phase 4C is complete! 🎉"

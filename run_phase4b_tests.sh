#!/bin/bash
# Phase 4B Test Runner
# Run this script from the renterinsight_api directory

echo "🧪 Running Phase 4B Tests..."
echo ""

echo "📋 Step 1: Running QuotePresenter tests..."
bundle exec rspec spec/services/quote_presenter_spec.rb --format documentation

echo ""
echo "📋 Step 2: Running QuotesController tests..."
bundle exec rspec spec/controllers/api/portal/quotes_controller_spec.rb --format documentation

echo ""
echo "📊 Summary: Running all Phase 4B tests..."
bundle exec rspec spec/services/quote_presenter_spec.rb spec/controllers/api/portal/quotes_controller_spec.rb --format progress

echo ""
echo "✅ Phase 4B tests complete!"

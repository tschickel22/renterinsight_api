#!/bin/bash
# Phase 4D - Run All Preference Tests

echo "=================================="
echo "Phase 4D - Preferences Test Runner"
echo "=================================="
echo ""

# Run controller specs
echo "📋 Running Controller Specs..."
bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb --format documentation

echo ""
echo "=================================="
echo ""

# Run model specs
echo "📋 Running Model Specs..."
bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb --format documentation

echo ""
echo "=================================="
echo ""

# Summary
echo "✅ All Phase 4D tests complete!"
echo ""
echo "To create test data and get curl commands:"
echo "  ruby create_test_preferences.rb"
echo ""

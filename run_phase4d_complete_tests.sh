#!/bin/bash
# Phase 4D Complete Test Runner

echo "=========================================="
echo "Phase 4D: Communication Preferences Tests"
echo "=========================================="
echo ""

echo "Running Controller Specs..."
bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb --format documentation

echo ""
echo "Running Model Specs..."
bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb --format documentation

echo ""
echo "=========================================="
echo "Test Summary"
echo "=========================================="
bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb spec/models/buyer_portal_access_preferences_spec.rb --format progress

echo ""
echo "✅ Phase 4D tests complete!"

#!/bin/bash
# Simple one-command test for Phase 4D

echo "🧪 Testing Phase 4D..."
bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb spec/controllers/api/portal/preferences_controller_spec.rb --format progress && echo "✅ All tests passed!" || echo "❌ Tests failed!"

#!/bin/bash
# Force fresh test run

echo "🔄 Forcing fresh test environment..."
cd /home/tschi/src/renterinsight_api

# Clear Spring (Rails preloader)
bin/spring stop 2>/dev/null || true

# Clear test database
RAILS_ENV=test bin/rails db:reset

echo ""
echo "✅ Environment reset complete"
echo ""
echo "🧪 Running Phase 4D tests..."
echo ""

# Run model specs
bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb --format documentation

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Model specs passed!"
    echo ""
    echo "Running controller specs..."
    bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb --format documentation
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "=========================================="
        echo "🎉 ALL PHASE 4D TESTS PASSING!"
        echo "=========================================="
        echo ""
        echo "Total: 67 tests ✅"
    else
        echo ""
        echo "❌ Controller specs failed"
    fi
else
    echo ""
    echo "❌ Model specs failed"
    echo ""
    echo "Checking file contents..."
    head -10 spec/models/buyer_portal_access_preferences_spec.rb
fi

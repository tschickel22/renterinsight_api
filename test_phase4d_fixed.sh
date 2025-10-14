#!/bin/bash
# Quick test after fixing the spec

echo "Testing Phase 4D model specs..."
echo ""

cd /home/tschi/src/renterinsight_api

bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb --format documentation

if [ $? -eq 0 ]; then
    echo ""
    echo "✅ Model specs passed! Now testing controller specs..."
    echo ""
    bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb --format documentation
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "=========================================="
        echo "✅ ALL TESTS PASSED!"
        echo "=========================================="
        echo ""
        echo "Phase 4D is working! 🎉"
    fi
else
    echo ""
    echo "❌ Model specs still failing. Check the output above."
fi

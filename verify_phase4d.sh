#!/bin/bash
# Quick Phase 4D Verification

echo "🚀 Phase 4D Quick Verification"
echo "=============================="
echo ""

# Check if files exist
echo "📁 Checking files..."
files=(
  "app/models/buyer_portal_access.rb"
  "app/controllers/api/portal/preferences_controller.rb"
  "spec/controllers/api/portal/preferences_controller_spec.rb"
  "spec/models/buyer_portal_access_preferences_spec.rb"
  "create_test_preferences.rb"
)

all_exist=true
for file in "${files[@]}"; do
  if [ -f "$file" ]; then
    echo "  ✅ $file"
  else
    echo "  ❌ $file (MISSING)"
    all_exist=false
  fi
done

echo ""

# Check routes
echo "📋 Checking routes..."
if bundle exec rails routes | grep -q "preferences"; then
  echo "  ✅ Preference routes found"
  bundle exec rails routes | grep "preferences"
else
  echo "  ❌ Preference routes not found"
fi

echo ""

# Run a quick syntax check
echo "🔍 Checking Ruby syntax..."
ruby -c app/models/buyer_portal_access.rb > /dev/null 2>&1 && echo "  ✅ Model syntax OK" || echo "  ❌ Model syntax error"
ruby -c app/controllers/api/portal/preferences_controller.rb > /dev/null 2>&1 && echo "  ✅ Controller syntax OK" || echo "  ❌ Controller syntax error"

echo ""

if [ "$all_exist" = true ]; then
  echo "✅ All Phase 4D files created successfully!"
  echo ""
  echo "Next steps:"
  echo "  1. Run tests: ./run_phase4d_tests.sh"
  echo "  2. Create test data: ruby create_test_preferences.rb"
  echo "  3. Start server: rails s -p 3001"
else
  echo "❌ Some files are missing. Please check the output above."
fi

echo ""

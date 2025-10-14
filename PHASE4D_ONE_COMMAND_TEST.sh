#!/bin/bash
# Phase 4D - One Command Test Runner
# Run this to test everything for Phase 4D

echo "=================================================="
echo "  Phase 4D: Communication Preferences"
echo "  Complete Test Suite"
echo "=================================================="
echo ""

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Navigate to project directory
cd "$(dirname "$0")"

echo -e "${BLUE}Step 1: Running Controller Tests...${NC}"
echo "-----------------------------------"
bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb \
  --format documentation \
  --color

CONTROLLER_EXIT=$?

echo ""
echo -e "${BLUE}Step 2: Running Model Tests...${NC}"
echo "-----------------------------------"
bundle exec rspec spec/models/buyer_portal_access_preferences_spec.rb \
  --format documentation \
  --color

MODEL_EXIT=$?

echo ""
echo "=================================================="
echo -e "${BLUE}Test Summary${NC}"
echo "=================================================="

bundle exec rspec spec/controllers/api/portal/preferences_controller_spec.rb \
  spec/models/buyer_portal_access_preferences_spec.rb \
  --format progress \
  --color

TOTAL_EXIT=$?

echo ""
echo "=================================================="
if [ $TOTAL_EXIT -eq 0 ]; then
    echo -e "${GREEN}✅ ALL TESTS PASSED!${NC}"
    echo ""
    echo "Phase 4D Implementation Status:"
    echo "  ✅ Controller (30+ tests)"
    echo "  ✅ Model (30+ tests)"
    echo "  ✅ Change tracking"
    echo "  ✅ Security validation"
    echo "  ✅ History tracking"
    echo ""
    echo "Next step: Run 'ruby create_test_preferences.rb' for test data"
else
    echo -e "${YELLOW}⚠️  Some tests failed. Review output above.${NC}"
    exit 1
fi

echo "=================================================="

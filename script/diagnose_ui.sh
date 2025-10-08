#!/bin/bash
# Quick diagnostic for UI issues

echo "========================================"
echo "UI Issues Diagnostic"
echo "========================================"
echo ""

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test CORS configuration
echo "1. Checking CORS configuration..."
if grep -q "127.0.0.1" config/initializers/cors.rb; then
    echo -e "${GREEN}✓ CORS allows 127.0.0.1${NC}"
else
    echo -e "${RED}✗ CORS does NOT allow 127.0.0.1${NC}"
    echo "   This will cause CORS errors in browser"
fi
echo ""

# Test settings controllers exist
echo "2. Checking settings controllers..."
if [ -f "app/controllers/api/company/settings_controller.rb" ]; then
    echo -e "${GREEN}✓ Company settings controller exists${NC}"
else
    echo -e "${RED}✗ Company settings controller MISSING${NC}"
fi

if [ -f "app/controllers/api/platform/settings_controller.rb" ]; then
    echo -e "${GREEN}✓ Platform settings controller exists${NC}"
else
    echo -e "${RED}✗ Platform settings controller MISSING${NC}"
fi
echo ""

# Test endpoints
echo "3. Testing critical endpoints..."
test_endpoint() {
    local path=$1
    local name=$2
    
    printf "   %-50s " "$name"
    
    status=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:3001$path" 2>/dev/null)
    
    if [ "$status" = "200" ]; then
        echo -e "${GREEN}✓ ($status)${NC}"
    elif [ "$status" = "404" ]; then
        echo -e "${RED}✗ 404 Not Found${NC}"
    elif [ "$status" = "500" ]; then
        echo -e "${RED}✗ 500 Server Error${NC}"
    elif [ "$status" = "000" ]; then
        echo -e "${RED}✗ Server not running${NC}"
    else
        echo -e "${YELLOW}⚠ $status${NC}"
    fi
}

test_endpoint "/api/company/settings" "Company Settings"
test_endpoint "/api/platform/settings" "Platform Settings"
test_endpoint "/api/crm/leads/1/reminders" "Reminders List"
test_endpoint "/api/crm/leads/1/activities" "Activities"
test_endpoint "/api/crm/leads/1/communications" "Communications"

echo ""
echo "========================================"
echo "Summary"
echo "========================================"

if grep -q "127.0.0.1" config/initializers/cors.rb; then
    echo -e "${GREEN}CORS is configured correctly ✓${NC}"
else
    echo -e "${RED}CRITICAL: Update CORS configuration${NC}"
    echo "Run: cat > config/initializers/cors.rb << 'EOF'"
    echo "# Then paste the cors_fix artifact content"
fi

if curl -s http://localhost:3001/up > /dev/null 2>&1; then
    echo -e "${GREEN}Rails server is running ✓${NC}"
else
    echo -e "${RED}Rails server is NOT running${NC}"
    echo "Start with: bin/rails s -p 3001"
fi

echo ""

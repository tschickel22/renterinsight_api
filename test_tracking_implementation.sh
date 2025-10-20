#!/bin/bash
# Test Email & SMS Tracking Implementation

echo "🧪 Email & SMS Tracking - Quick Test Script"
echo "=========================================="
echo ""

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${BLUE}📋 Checking Backend Implementation...${NC}"
echo ""

# Check webhook controllers exist
echo "1. Checking webhook controllers..."
if [ -f "app/controllers/webhooks/email_tracking_controller.rb" ]; then
    echo -e "   ${GREEN}✓${NC} EmailTrackingController exists"
else
    echo -e "   ${RED}✗${NC} EmailTrackingController missing"
fi

if [ -f "app/controllers/webhooks/twilio_controller.rb" ]; then
    echo -e "   ${GREEN}✓${NC} TwilioController exists"
else
    echo -e "   ${RED}✗${NC} TwilioController missing"
fi

echo ""

# Check routes
echo "2. Checking routes..."
if grep -q "webhooks/email/:communication_id/pixel.gif" config/routes.rb; then
    echo -e "   ${GREEN}✓${NC} Email tracking route configured"
else
    echo -e "   ${YELLOW}⚠${NC}  Email tracking route not found"
fi

if grep -q "webhooks/twilio/sms/status" config/routes.rb; then
    echo -e "   ${GREEN}✓${NC} Twilio webhook route configured"
else
    echo -e "   ${YELLOW}⚠${NC}  Twilio webhook route not found"
fi

echo ""

# Check database schema
echo "3. Checking database schema..."
if grep -q "t.datetime \"read_at\"" db/schema.rb; then
    echo -e "   ${GREEN}✓${NC} read_at column exists"
else
    echo -e "   ${RED}✗${NC} read_at column missing"
fi

if grep -q "t.datetime \"delivered_at\"" db/schema.rb; then
    echo -e "   ${GREEN}✓${NC} delivered_at column exists"
else
    echo -e "   ${RED}✗${NC} delivered_at column missing"
fi

if grep -q "t.string \"external_id\"" db/schema.rb; then
    echo -e "   ${GREEN}✓${NC} external_id column exists"
else
    echo -e "   ${RED}✗${NC} external_id column missing"
fi

echo ""

# Check models
echo "4. Checking models..."
if grep -q "mark_as_opened" app/models/communication.rb; then
    echo -e "   ${GREEN}✓${NC} Communication model has tracking methods"
else
    echo -e "   ${YELLOW}⚠${NC}  Communication model may be missing tracking methods"
fi

if grep -q "track_open" app/models/communication_event.rb; then
    echo -e "   ${GREEN}✓${NC} CommunicationEvent has tracking helpers"
else
    echo -e "   ${YELLOW}⚠${NC}  CommunicationEvent may be missing tracking helpers"
fi

echo ""

# Check controller helpers
echo "5. Checking communications controller..."
if grep -q "add_tracking_pixel" app/controllers/api/platform/communications_controller.rb; then
    echo -e "   ${GREEN}✓${NC} Tracking pixel helper exists"
else
    echo -e "   ${YELLOW}⚠${NC}  Tracking pixel helper not found"
fi

if grep -q "create_pending_communication" app/controllers/api/platform/communications_controller.rb; then
    echo -e "   ${GREEN}✓${NC} Pending communication helper exists"
else
    echo -e "   ${YELLOW}⚠${NC}  Pending communication helper not found"
fi

echo ""
echo "=========================================="
echo -e "${BLUE}🧪 Manual Testing Steps:${NC}"
echo ""

echo -e "${YELLOW}Test 1: Email Open Tracking${NC}"
echo "1. Send test email via Communication Center"
echo "2. Open the email in your email client"
echo "3. Check logs: tail -f log/development.log | grep EmailTracking"
echo "4. Verify in console:"
echo "   rails c"
echo "   comm = Communication.last"
echo "   comm.read_at  # Should show timestamp after opening"
echo ""

echo -e "${YELLOW}Test 2: SMS Delivery Tracking${NC}"
echo "1. Start ngrok (for local testing):"
echo "   ngrok http 3001"
echo "2. Update callback URL in code to use ngrok URL"
echo "3. Send test SMS via Communication Center"
echo "4. Check logs: tail -f log/development.log | grep Twilio"
echo "5. Verify in console:"
echo "   rails c"
echo "   comm = Communication.where(channel: 'sms').last"
echo "   comm.delivered_at  # Should show timestamp after delivery"
echo "   comm.external_id   # Should have Twilio MessageSid"
echo ""

echo -e "${YELLOW}Test 3: Frontend Display${NC}"
echo "1. Open browser to Communication Center"
echo "2. Navigate to Contact with sent messages"
echo "3. Check History tab for read receipt indicators:"
echo "   - 👁️ Read [date] (green) for opened emails"
echo "   - ✓ Delivered [date] (blue) for delivered SMS"
echo ""

echo "=========================================="
echo -e "${GREEN}✅ Implementation Check Complete!${NC}"
echo ""
echo "See TRACKING_IMPLEMENTATION_COMPLETE.md for detailed documentation"
echo ""

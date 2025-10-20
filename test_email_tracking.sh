#!/bin/bash
# Quick test script for email/SMS tracking

echo "🧪 Testing Email & SMS Tracking"
echo "================================"
echo ""

read -p "Enter the Communication ID of the email you just sent: " COMM_ID

if [ -z "$COMM_ID" ]; then
  echo "❌ No ID provided. Exiting."
  exit 1
fi

echo ""
echo "📧 Testing email tracking for Communication #$COMM_ID..."
echo ""

# Test 1: Check if communication exists
echo "1. Checking if communication exists..."
COMM_EXISTS=$(curl -s http://localhost:3001/webhooks/email/$COMM_ID/pixel.gif -o /dev/null -w "%{http_code}")

if [ "$COMM_EXISTS" = "200" ]; then
  echo "   ✅ Communication exists and webhook responds"
  echo "   📊 Tracking pixel loaded - read_at should be updated"
else
  echo "   ❌ Webhook returned status: $COMM_EXISTS"
  echo "   ⚠️  Communication might not exist or webhook has error"
fi

echo ""
echo "2. Triggering tracking pixel..."
curl -s "http://localhost:3001/webhooks/email/$COMM_ID/pixel.gif" > /dev/null
echo "   ✅ Pixel triggered"

echo ""
echo "3. Waiting 2 seconds for database update..."
sleep 2

echo ""
echo "================================================================"
echo "✅ Test Complete!"
echo ""
echo "Next steps:"
echo "1. Open Rails console: rails c"
echo "2. Run: Communication.find($COMM_ID).read_at"
echo "3. Should show a timestamp"
echo "4. Refresh your browser's Communication Center"
echo "5. Should see 👁️ 'Read' indicator"
echo ""
echo "If read_at is still null, check:"
echo "- Rails logs: tail -f log/development.log"
echo "- Webhook controller exists"
echo "- Communication ID is correct"
echo "================================================================"

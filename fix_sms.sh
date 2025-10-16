#!/bin/bash
# Quick SMS Debug and Fix

echo "🔍 SMS Debug and Fix"
echo "===================="
echo ""

cd ~/src/renterinsight_api

echo "Step 1: Check if twilio-ruby gem is installed"
echo "-----------------------------------------------"
if bundle list | grep -q "twilio-ruby"; then
    echo "✅ twilio-ruby gem is installed"
    bundle list | grep twilio
else
    echo "❌ twilio-ruby gem NOT installed"
    echo ""
    echo "Installing twilio-ruby..."
    bundle add twilio-ruby
    echo ""
    echo "✅ twilio-ruby installed!"
fi

echo ""
echo "Step 2: Running SMS diagnostic"
echo "-----------------------------------------------"
bundle exec rails runner debug_sms_issue.rb

echo ""
echo "===================="
echo "✅ Complete!"
echo ""
echo "If SMS is still failing, the error message above will tell you why."
echo ""
echo "Common issues:"
echo "  1. Twilio gem not installed (we just fixed this if needed)"
echo "  2. Twilio credentials invalid"
echo "  3. Twilio account needs funding"
echo "  4. From number not verified in Twilio"

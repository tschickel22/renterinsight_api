#!/bin/bash
# Complete Settings Integration - One Command Test

echo "🚀 Testing Password Reset with Live Settings"
echo "=============================================="
echo ""

cd ~/src/renterinsight_api

echo "Step 1: Running Settings Integration Test..."
echo "---------------------------------------------"
bundle exec rails runner test_settings_integration.rb
echo ""

echo "=============================================="
echo "✅ COMPLETE!"
echo ""
echo "🎯 Next: Test with curl commands shown above"
echo ""
echo "📧 Email should now actually send (not test mode)"
echo "📱 SMS should send via Twilio (if configured)"
echo ""
echo "💡 Watch logs live:"
echo "   tail -f log/development.log | grep -E '(Using|ActionMailer|password_reset)'"

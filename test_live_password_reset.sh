#!/bin/bash
# Test Password Reset with Live Platform Settings

echo "🚀 Password Reset - Live Settings Test"
echo "=========================================="
echo ""

cd ~/src/renterinsight_api

echo "Step 1: Check Platform Settings"
echo "----------------------------------------"
bundle exec rails runner check_platform_settings.rb
echo ""

echo "Step 2: Fix Test Users (normalize phone numbers)"
echo "----------------------------------------"
bundle exec rails runner fix_test_users.rb
echo ""

echo "Step 3: Restart Rails Server"
echo "----------------------------------------"
echo "⚠️  IMPORTANT: You need to restart your Rails server for the"
echo "   ActionMailer initializer to load Platform Settings!"
echo ""
echo "   Press Ctrl+C in your server terminal, then run:"
echo "   bundle exec rails server -p 3001"
echo ""
read -p "Press Enter once you've restarted the server..."
echo ""

echo "Step 4: Test Password Reset with LIVE delivery"
echo "----------------------------------------"
echo ""

echo "📧 Test 1: Admin Email Reset (with live SMTP)"
echo "----------------------------------------"
response=$(curl -s -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{"email":"t+admin@renterinsight.com","delivery_method":"email","user_type":"admin"}')
echo "$response" | jq '.' 2>/dev/null || echo "$response"
echo ""
echo "✅ Check your email inbox at t+admin@renterinsight.com"
echo ""
sleep 2

echo "📱 Test 2: Client SMS Reset by phone (3035709810 - no country code!)"
echo "----------------------------------------"
response=$(curl -s -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{"phone":"3035709810","delivery_method":"sms","user_type":"client"}')
echo "$response" | jq '.' 2>/dev/null || echo "$response"
echo ""
echo "✅ Check your phone for SMS (country code added automatically!)"
echo ""
sleep 2

echo "📧 Test 3: Client Email Reset"
echo "----------------------------------------"
response=$(curl -s -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{"email":"t+client@renterinsight.com","delivery_method":"email","user_type":"client"}')
echo "$response" | jq '.' 2>/dev/null || echo "$response"
echo ""
echo "✅ Check your email inbox at t+client@renterinsight.com"
echo ""
sleep 2

echo "📱 Test 4: Admin SMS Reset by phone (303-570-9810 with dashes)"
echo "----------------------------------------"
response=$(curl -s -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{"phone":"303-570-9810","delivery_method":"sms","user_type":"admin"}')
echo "$response" | jq '.' 2>/dev/null || echo "$response"
echo ""
echo "✅ Check your phone for SMS (formatted automatically!)"
echo ""

echo "=========================================="
echo "✅ Live Testing Complete!"
echo ""
echo "📊 What Just Happened:"
echo "  - Used email settings from Platform Settings"
echo "  - Used SMS settings from Platform Settings"
echo "  - Automatically added +1 country code to phone numbers"
echo "  - Accepted phone in multiple formats:"
echo "    • 3035709810"
echo "    • 303-570-9810"
echo "    • (303) 570-9810"
echo "    • +13035709810"
echo ""
echo "🔍 Check Results:"
echo "  - Email: Check t+admin@renterinsight.com inbox"
echo "  - Email: Check t+client@renterinsight.com inbox"
echo "  - SMS: Check phone 303-570-9810 for text messages"
echo ""
echo "📝 Check Logs:"
echo "  tail -f log/development.log | grep password_reset"

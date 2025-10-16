#!/bin/bash
# Install Twilio Gem and Test SMS

echo "📦 Installing twilio-ruby gem..."
echo "================================"
echo ""

cd ~/src/renterinsight_api

echo "Running bundle install..."
bundle install

echo ""
echo "================================"
echo "✅ twilio-ruby installed!"
echo ""
echo "🧪 Now test SMS again:"
echo ""
echo "curl -X POST http://localhost:3001/api/auth/request_password_reset \\"
echo "  -H 'Content-Type: application/json' \\"
echo "  -d '{\"phone\":\"303-570-9810\",\"delivery_method\":\"sms\",\"user_type\":\"client\"}'"
echo ""
echo "Expected: {\"success\":true,\"message\":\"Reset instructions sent successfully\",\"delivery_method\":\"sms\"}"
echo ""
echo "💡 If you need to restart Rails server:"
echo "   pkill -f puma"
echo "   bin/rails server -p 3001"

#!/bin/bash
# Complete Debug and Fix for Password Reset

echo "🔧 Password Reset - Debug and Fix"
echo "=========================================="
echo ""

cd ~/src/renterinsight_api

echo "Step 1: Fix Test Users (phone numbers)"
echo "----------------------------------------"
bundle exec rails runner fix_test_users.rb
echo ""

echo "Step 2: Test Email Configuration"
echo "----------------------------------------"
bundle exec rails runner test_email_config.rb
echo ""

echo "Step 3: Test Password Reset Flow"
echo "----------------------------------------"
echo ""

echo "Testing Admin Email Reset..."
response=$(curl -s -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{"email":"t+admin@renterinsight.com","delivery_method":"email","user_type":"admin"}')
echo "$response" | jq '.' 2>/dev/null || echo "$response"
echo ""

echo "Testing Client SMS Reset (phone)..."
response=$(curl -s -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{"phone":"+13035709810","delivery_method":"sms","user_type":"client"}')
echo "$response" | jq '.' 2>/dev/null || echo "$response"
echo ""

echo "=========================================="
echo "✅ Debug Complete!"
echo ""
echo "📧 EMAIL DELIVERY:"
echo "  - Emails are captured in TEST mode (not actually sent)"
echo "  - Check Rails logs to see email content"
echo "  - In Rails console: ActionMailer::Base.deliveries.last"
echo ""
echo "📱 SMS DELIVERY:"
echo "  - SMS requires Twilio configuration"
echo "  - Configure in Settings or ENV variables"
echo ""
echo "🔍 CHECK LOGS:"
echo "  tail -f log/development.log | grep password_reset"
echo ""
echo "⚙️  TO SEND REAL EMAILS:"
echo "  1. Add to .env file:"
echo "     SMTP_ADDRESS=smtp.gmail.com"
echo "     SMTP_PORT=587"
echo "     SMTP_USERNAME=your_email@gmail.com"
echo "     SMTP_PASSWORD=your_app_password"
echo ""
echo "  2. Update config/environments/development.rb:"
echo "     config.action_mailer.delivery_method = :smtp"
echo "     config.action_mailer.smtp_settings = {"
echo "       address: ENV['SMTP_ADDRESS'],"
echo "       port: ENV['SMTP_PORT'],"
echo "       user_name: ENV['SMTP_USERNAME'],"
echo "       password: ENV['SMTP_PASSWORD'],"
echo "       authentication: 'plain',"
echo "       enable_starttls_auto: true"
echo "     }"
echo ""
echo "  3. Restart Rails server"

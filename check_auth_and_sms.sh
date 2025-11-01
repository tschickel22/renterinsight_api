#!/bin/bash
# Check Authentication Routes and SMS Settings

cd ~/src/renterinsight_api

echo "=========================================="
echo "🔍 Auth Routes & SMS Settings Check"
echo "=========================================="
echo ""

# Check available users
echo "1️⃣  Available Test Users:"
echo "-------------------------"
bundle exec rails runner "
User.limit(5).each do |u|
  puts \"  📧 #{u.email}\"
end
"
echo ""

# Check auth routes
echo "2️⃣  Authentication Routes:"
echo "--------------------------"
bundle exec rails routes | grep -i "auth.*login"
echo ""

# Check Platform SMS settings
echo "3️⃣  Platform SMS Settings:"
echo "--------------------------"
bundle exec rails runner "
platform = CommunicationSettingsService.platform
sms = platform.sms_config
puts \"  Twilio Account SID: #{sms[:twilio_account_sid].present? ? '✅ Configured' : '❌ Missing'}\"
puts \"  Twilio Auth Token:  #{sms[:twilio_auth_token].present? ? '✅ Configured' : '❌ Missing'}\"
puts \"  From Number:        #{sms[:from_number] || '❌ Missing'}\"
"
echo ""

# Check Company SMS settings
echo "4️⃣  Company SMS Settings:"
echo "-------------------------"
bundle exec rails runner "
if Company.exists?
  company = Company.first
  puts \"  Company: #{company.name}\"
  comp_settings = CommunicationSettingsService.for_company(company)
  comp_sms = comp_settings.sms_config
  
  platform = CommunicationSettingsService.platform
  platform_sms = platform.sms_config
  
  # Check if company is overriding platform settings
  if comp_sms[:twilio_account_sid] && comp_sms[:twilio_account_sid] != platform_sms[:twilio_account_sid]
    puts \"  Twilio Account SID: ✅ Overriding platform\"
  else
    puts \"  Twilio Account SID: ⚪ Using platform settings\"
  end
  
  if comp_sms[:twilio_auth_token] && comp_sms[:twilio_auth_token] != platform_sms[:twilio_auth_token]
    puts \"  Twilio Auth Token:  ✅ Overriding platform\"
  else
    puts \"  Twilio Auth Token:  ⚪ Using platform settings\"
  end
  
  if comp_sms[:from_number] && comp_sms[:from_number] != platform_sms[:from_number]
    puts \"  From Number:        ✅ Overriding platform (#{comp_sms[:from_number]})\"
  else
    puts \"  From Number:        ⚪ Using platform settings\"
  end
else
  puts '  No companies found'
end
"
echo ""

# Check MFA routes
echo "5️⃣  MFA Routes (SMS + TOTP):"
echo "----------------------------"
bundle exec rails routes | grep "mfa" | head -15
echo ""

echo "=========================================="
echo "✅ Check Complete!"
echo "=========================================="

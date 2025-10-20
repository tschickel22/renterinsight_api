# 🚀 SMS Quick Start Guide

## Test SMS Right Now!

### Option 1: Run Test Script (Easiest)
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails runner test_sms_simple.rb
```

When prompted, enter your phone number (e.g., `+17205752095`)

Expected result: You should receive 1-2 SMS messages on your phone!

---

### Option 2: Rails Console
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails console
```

Then in the console:

```ruby
# Send a simple test SMS
result = CommunicationService.send_sms(
  communicable: Contact.first,  # or any model
  to: '+17205752095',           # YOUR phone number
  body: 'Test SMS from RenterInsight!'
)

# Check result
puts result.inspect
# Should show: { success: true, communication: #<Communication...>, ... }

# Check your phone for the SMS!
```

---

### Option 3: Via API (If you have API access)

```bash
# Send SMS to a contact
curl -X POST http://localhost:3000/api/v1/contacts/1/communications/send_sms \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -d '{
    "to": "+17205752095",
    "body": "Your appointment is confirmed for tomorrow at 2 PM.",
    "category": "appointments"
  }'
```

---

## Configuration Check

### Check Current SMS Settings

```ruby
# In Rails console:

# Check platform settings
settings = CommunicationSettingsService.platform
puts settings.sms_config.inspect

# Check company settings (if you have a company)
company = Company.first
settings = CommunicationSettingsService.for_company(company)
puts settings.sms_config.inspect
```

Expected output:
```ruby
{
  :twilio_account_sid => "ACxxxxx",
  :twilio_auth_token => "xxxxx",
  :from_number => "+17205752095"
}
```

---

## Troubleshooting

### "No SMS settings configured"
**Fix:** Set up platform settings:
```ruby
PlatformSetting.set(:sms, :twilio_account_sid, 'YOUR_ACCOUNT_SID')
PlatformSetting.set(:sms, :twilio_auth_token, 'YOUR_AUTH_TOKEN')
PlatformSetting.set(:sms, :from_number, '+17205752095')
```

Or set environment variables:
```bash
export TWILIO_ACCOUNT_SID=ACxxxxx
export TWILIO_AUTH_TOKEN=xxxxx
export TWILIO_PHONE_NUMBER=+17205752095
```

### "twilio-ruby gem not found"
**Fix:** Add to Gemfile and bundle install:
```ruby
gem 'twilio-ruby'
```

### SMS not received
1. Check Twilio account has credits
2. Verify phone number is verified in Twilio (if trial account)
3. Check Rails logs for errors: `tail -f log/development.log`
4. Check Communication record: `Communication.last`

---

## What's Working

✅ **Email Integration** - Fully operational  
✅ **SMS Integration** - Fully operational  
✅ **Configuration Hierarchy** - Company → Platform → ENV  
✅ **Service Layer** - Unified architecture  
✅ **Controllers** - Using service layer  
✅ **Test Scripts** - Available for verification  

---

## Files You Can Test

- `test_sms_simple.rb` - Interactive SMS test
- `test_sms_config.rb` - Configuration check

Both in: `/home/tschi/src/renterinsight_api/`

---

## Need Help?

Check the detailed documentation:
- `SMS_INTEGRATION_STATUS.md` - Complete integration details
- `EMAIL_INTEGRATION_STATUS.md` - Email integration details

**Happy testing! 📱**

# SMS Integration Testing Checklist

## Prerequisites

### 1. Environment Configuration
- [ ] `TWILIO_ACCOUNT_SID` set in environment
- [ ] `TWILIO_AUTH_TOKEN` set in environment  
- [ ] `TWILIO_PHONE_NUMBER` set in environment
- [ ] Twilio phone number is verified in Twilio console
- [ ] Test phone number is verified in Twilio (for trial accounts)

### 2. Database Configuration
- [ ] Platform SMS settings configured in Settings table
- [ ] At least one company exists for company-level testing
- [ ] Test contact exists with valid phone number
- [ ] Test account exists with valid phone number

## Test Sequence

### Phase 1: Configuration Loading (5 minutes)
Run these in Rails console (`bundle exec rails console`):

```ruby
# 1. Test platform settings
settings = CommunicationSettingsService.platform
sms_config = settings.sms_config
puts sms_config.inspect
# Expected: Hash with twilio_account_sid, twilio_auth_token, from_number

# 2. Test company settings (if company exists)
company = Company.first
if company
  settings = CommunicationSettingsService.for_company(company)
  sms_config = settings.sms_config
  puts sms_config.inspect
  # Should show company settings if configured, else platform settings
end

# 3. Verify hierarchy is working
# Create a test company setting
company = Company.first
Setting.create!(
  scope_type: 'Company',
  scope_id: company.id,
  key: 'communications',
  value: {
    sms: {
      provider: 'twilio',
      enabled: true,
      from_number: '+17205752095',
      twilio_account_sid: 'TEST_SID',
      twilio_auth_token: 'TEST_TOKEN'
    }
  }.to_json
)

# Now check if company settings override platform
settings = CommunicationSettingsService.for_company(company)
puts settings.sms_config[:twilio_account_sid]
# Should show 'TEST_SID'

# Clean up test setting
Setting.where(scope_type: 'Company', scope_id: company.id, key: 'communications').delete_all
```

**Results:**
- [ ] Platform settings loaded successfully
- [ ] Company settings loaded successfully
- [ ] Company settings override platform settings
- [ ] ENV fallback works when no DB settings exist

---

### Phase 2: Provider Initialization (3 minutes)

```ruby
# 1. Test platform-level provider
provider = Providers::Sms::TwilioProvider.new
puts "Configured: #{provider.configured?}"
# Expected: true

# 2. Test company-level provider
company = Company.first
provider = Providers::Sms::TwilioProvider.new(company: company)
puts "Configured: #{provider.configured?}"
# Expected: true
```

**Results:**
- [ ] Platform provider initializes successfully
- [ ] Company provider initializes successfully
- [ ] Provider shows as configured

---

### Phase 3: Direct Service Testing (5 minutes)

```ruby
# 1. Test SmsService directly (platform-level)
result = SmsService.send_sms(
  to: '+17205752095',  # Replace with your phone
  body: 'Test SMS from platform settings'
)
puts result.inspect
# Expected: { success: true, message_id: '...', response: {...} }

# 2. Test SmsService with company
company = Company.first
result = SmsService.send_sms(
  to: '+17205752095',  # Replace with your phone
  body: "Test SMS from company #{company.name}",
  company: company
)
puts result.inspect
# Expected: { success: true, message_id: '...', response: {...} }

# 3. Check communication record was created
comm = Communication.where(channel: 'sms').order(created_at: :desc).first
puts "Status: #{comm.status}"
puts "Provider: #{comm.provider}"
puts "Message ID: #{comm.provider_message_id}"
# Expected: status='sent', provider='twilio', message_id present
```

**Results:**
- [ ] Platform-level SMS sends successfully
- [ ] Company-level SMS sends successfully  
- [ ] Communication records created in database
- [ ] SMS messages received on test phone

---

### Phase 4: CommunicationService Testing (5 minutes)

```ruby
# 1. Create test account
account = Account.first || Account.create!(
  name: 'Test Account',
  phone: '+17205752095',
  company: Company.first
)

# 2. Send via CommunicationService
result = CommunicationService.send_sms(
  communicable: account,
  to: account.phone,
  body: 'Test SMS via CommunicationService',
  category: 'transactional',
  metadata: { test: true }
)
puts result.inspect
# Expected: { success: true, communication: <Communication>, ... }

# 3. Check communication
comm = result[:communication]
puts "ID: #{comm.id}"
puts "Status: #{comm.status}"
puts "Category: #{comm.metadata['category']}"
# Expected: status='sent', category='transactional'
```

**Results:**
- [ ] CommunicationService sends SMS successfully
- [ ] Communication linked to account
- [ ] Metadata saved correctly
- [ ] SMS received on test phone

---

### Phase 5: Controller/API Testing (10 minutes)

#### 5A. Test Contact SMS Endpoint

```bash
# Get auth token first
TOKEN="your_jwt_token_here"

# Send SMS to contact
curl -X POST http://localhost:3000/api/v1/contacts/123/communications/sms \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "message": "Test SMS from API to contact"
  }'

# Expected response:
# { "ok": true, "id": 456, "provider": "twilio" }
```

**Results:**
- [ ] API endpoint accepts request
- [ ] SMS sends successfully
- [ ] Response includes communication ID
- [ ] SMS received on test phone

#### 5B. Test Account SMS Endpoint

```bash
# Send SMS to account
curl -X POST http://localhost:3000/api/v1/accounts/456/communications/sms \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{
    "message": "Test SMS from API to account",
    "to": "+17205752095"
  }'

# Expected response:
# { "ok": true, "id": 789, "provider": "twilio" }
```

**Results:**
- [ ] API endpoint accepts request
- [ ] SMS sends successfully
- [ ] Response includes communication ID
- [ ] SMS received on test phone

---

### Phase 6: Quote Sending Integration (10 minutes)

```ruby
# 1. Find or create test quote
quote = Quote.first || Quote.create!(
  quote_number: 'TEST-001',
  account: Account.first,
  contact: Contact.first,
  total: 100.00,
  subtotal: 90.00,
  tax: 10.00,
  valid_until: 30.days.from_now
)

# 2. Send quote via SMS
service = QuoteSendingService.new(quote)
result = service.send(
  delivery_methods: ['sms'],
  to_phone: '+17205752095'  # Replace with your phone
)

puts "Sent: #{result[:sent].length}"
puts "Failed: #{result[:failed].length}"
puts "Errors: #{result[:errors].inspect}"

# 3. Check communication
if result[:sent].any?
  comm = result[:sent].first[:communication]
  puts "Communication ID: #{comm.id}"
  puts "Status: #{comm.status}"
  puts "Body preview: #{comm.body[0..100]}"
end
```

**Results:**
- [ ] Quote SMS sends successfully
- [ ] SMS contains quote number
- [ ] SMS contains total amount
- [ ] SMS contains portal link (if configured)
- [ ] SMS received on test phone

---

### Phase 7: Test Scripts Execution (5 minutes)

#### 7A. Run Simple Test

```bash
cd /path/to/renterinsight_api
bundle exec rails runner test_sms_simple.rb
# Follow prompts to enter phone number
```

**Results:**
- [ ] Platform-level SMS test passes
- [ ] Company-level SMS test passes (if company exists)
- [ ] Test messages received

#### 7B. Run Comprehensive Test

```bash
bundle exec rails runner test_sms_config.rb
# May need to edit script to use correct quote ID and phone number
```

**Results:**
- [ ] Configuration loads successfully
- [ ] Provider initializes successfully
- [ ] Quote SMS sends successfully
- [ ] Communication record created correctly

---

## Error Scenarios to Test

### 1. Missing Configuration
```ruby
# Temporarily remove ENV variables
old_sid = ENV['TWILIO_ACCOUNT_SID']
ENV['TWILIO_ACCOUNT_SID'] = nil

result = SmsService.send_sms(to: '+17205752095', body: 'Test')
puts result.inspect
# Expected: { success: false, error: 'Provider not configured' }

# Restore
ENV['TWILIO_ACCOUNT_SID'] = old_sid
```

**Results:**
- [ ] Returns proper error when not configured
- [ ] Does not crash application
- [ ] Error message is clear

### 2. Invalid Phone Number
```ruby
result = SmsService.send_sms(to: 'invalid', body: 'Test')
puts result.inspect
# Expected: { success: false, error: 'Invalid phone number...' }
```

**Results:**
- [ ] Returns proper error for invalid phone
- [ ] Does not crash application
- [ ] Communication record marked as failed

### 3. Opted Out Contact
```ruby
contact = Contact.first
contact.update!(communication_preferences: { sms: { opted_out: true } })

result = CommunicationService.send_sms(
  communicable: contact,
  to: contact.phone,
  body: 'Test'
)
# Expected: OptOutError raised

contact.update!(communication_preferences: nil)  # Reset
```

**Results:**
- [ ] Raises OptOutError
- [ ] Does not send SMS
- [ ] API returns 422 status

---

## Monitoring & Verification

### Database Checks
```sql
-- Check recent communications
SELECT id, channel, status, provider, to_address, created_at 
FROM communications 
WHERE channel = 'sms' 
ORDER BY created_at DESC 
LIMIT 10;

-- Check for failed communications
SELECT id, status, metadata->'error' as error, created_at
FROM communications 
WHERE channel = 'sms' AND status = 'failed'
ORDER BY created_at DESC 
LIMIT 10;

-- Check settings
SELECT scope_type, scope_id, key, 
       value::json->'sms'->'provider' as sms_provider,
       value::json->'sms'->'enabled' as sms_enabled
FROM settings 
WHERE key = 'communications';
```

### Twilio Console Checks
- [ ] Check Twilio message logs for sent messages
- [ ] Verify message status is 'delivered'
- [ ] Check for any error codes
- [ ] Verify 'from' number matches configuration

### Application Logs
```bash
# Tail Rails logs
tail -f log/development.log | grep -i 'sms\|twilio'

# Look for:
# - "Initialized with company X settings"
# - "SMS sent successfully"
# - Any error messages
```

---

## Success Criteria

✅ **All tests must pass for sign-off:**

1. [ ] Configuration loads correctly from all three sources (ENV, Platform, Company)
2. [ ] Configuration hierarchy works (Company > Platform > ENV)
3. [ ] Platform-level SMS sends successfully
4. [ ] Company-level SMS sends successfully  
5. [ ] API endpoints work correctly
6. [ ] Quote SMS sends with proper formatting
7. [ ] Communication records created in database
8. [ ] Error handling works for all edge cases
9. [ ] All test messages received on test phone
10. [ ] Twilio dashboard shows all sent messages

---

## Rollback Plan

If issues are found:

1. **Revert TwilioProvider changes:**
   ```bash
   git checkout HEAD~1 app/services/providers/sms/twilio_provider.rb
   ```

2. **Revert Controller changes:**
   ```bash
   git checkout HEAD~1 app/controllers/api/v1/*_communications_controller.rb
   ```

3. **Revert SmsService changes:**
   ```bash
   git checkout HEAD~1 app/services/sms_service.rb
   ```

4. **Restart Rails server:**
   ```bash
   bin/rails restart
   ```

---

## Notes

- Test phone number: +17205752095 (UPDATE THIS)
- Twilio Account SID: AC... (from ENV)
- Test environment: Development
- Estimated total testing time: 45-60 minutes

**Tester:** _________________  
**Date:** _________________  
**Result:** ☐ PASS ☐ FAIL  
**Notes:** _________________

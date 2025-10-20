# UI Simplification - From Address Removed

**Date:** October 19, 2025  
**Change:** Removed "From Email" and "From Phone" fields from Send Quote UI  
**Reason:** Simplify UX - addresses now automatically pulled from settings

---

## What Changed

### Frontend (SendQuoteModal.tsx)
✅ **Removed Fields:**
- "From Email Address" field (Advanced Options)
- "From Phone Number" field (Advanced Options)

✅ **Kept Fields:**
- CC (email carbon copy)
- BCC (email blind carbon copy)
- Send in background (async option)

### Backend (CommunicationService)
✅ **Updated:** Both email and SMS now use unified settings hierarchy:

```ruby
def default_from_address(channel, communicable = nil)
  # Get from CommunicationSettingsService for both email and SMS
  company = extract_company_from_communicable(communicable)
  settings_service = company ? 
    CommunicationSettingsService.for_company(company) : 
    CommunicationSettingsService.platform
  
  case channel
  when 'email'
    email_config = settings_service.email_config
    email_config[:from_email]  # Company → Platform → ENV → Default
  when 'sms'
    sms_config = settings_service.sms_config
    sms_config[:from_number]   # Company → Platform → ENV
  end
end
```

---

## Configuration Hierarchy (Both Email and SMS)

### For Email:
```
1. Company settings (communications.email.fromEmail)
   ↓
2. Platform settings (communications.email.fromEmail)
   ↓
3. ENV['DEFAULT_FROM_EMAIL']
   ↓
4. 'noreply@platformdms.com' (hardcoded default)
```

### For SMS:
```
1. Company settings (communications.sms.fromNumber)
   ↓
2. Platform settings (communications.sms.fromNumber)
   ↓
3. ENV['TWILIO_PHONE_NUMBER']
   ↓
4. Validation error (no default)
```

---

## How to Configure

### Email Settings

**Platform-wide (all companies):**
```ruby
# Via Settings model (recommended)
Setting.create!(
  key: 'communications',
  scope_type: 'Platform',
  value: {
    email: {
      fromEmail: 'noreply@yourcompany.com',
      fromName: 'Your Company Name',
      provider: 'smtp'
    }
  }.to_json
)
```

**Per-company:**
```ruby
company = Company.find(1)
Setting.create!(
  key: 'communications',
  scope_type: 'Company',
  scope_id: company.id,
  value: {
    email: {
      fromEmail: 'sales@company1.com',
      fromName: 'Company 1 Sales'
    }
  }.to_json
)
```

**Environment variable (fallback):**
```bash
DEFAULT_FROM_EMAIL=noreply@yourcompany.com
DEFAULT_FROM_NAME=Your Company
```

### SMS Settings

**Platform-wide (all companies):**
```ruby
# Via Settings model (recommended)
Setting.create!(
  key: 'communications',
  scope_type: 'Platform',
  value: {
    sms: {
      fromNumber: '+17205752095',
      twilioAccountSid: 'ACxxxxx',
      twilioAuthToken: 'xxxxx',
      provider: 'twilio'
    }
  }.to_json
)
```

**Per-company:**
```ruby
company = Company.find(1)
Setting.create!(
  key: 'communications',
  scope_type: 'Company',
  scope_id: company.id,
  value: {
    sms: {
      fromNumber: '+17205551234'
    }
  }.to_json
)
```

**Environment variable (fallback):**
```bash
TWILIO_PHONE_NUMBER=+17205752095
TWILIO_ACCOUNT_SID=ACxxxxx
TWILIO_AUTH_TOKEN=xxxxx
```

---

## User Experience

### Before:
```
Send Quote Dialog
├── Delivery Methods (Email/SMS)
├── Recipient info (email/phone)
├── Custom Message
└── Advanced Options
    ├── From Email Address     ← User had to manage
    ├── From Phone Number      ← User had to manage
    ├── CC
    ├── BCC
    └── Send in background
```

### After:
```
Send Quote Dialog
├── Delivery Methods (Email/SMS)
├── Recipient info (email/phone)
├── Custom Message
└── Advanced Options
    ├── CC                     ← Kept
    ├── BCC                    ← Kept
    └── Send in background     ← Kept

From addresses automatically pulled from settings!
```

---

## Benefits

✅ **Simpler UI** - Less fields to fill out  
✅ **Fewer errors** - No validation issues with from addresses  
✅ **Centralized control** - Admins set from addresses once  
✅ **Consistency** - All communications use same from address  
✅ **Company branding** - Each company can have their own from addresses  
✅ **Fallback safety** - ENV variables provide backup configuration  

---

## Advanced Options Now

The **Advanced Options** section now only contains:

1. **CC** (Email only)
   - Carbon copy recipients
   - Comma-separated email addresses
   
2. **BCC** (Email only)
   - Blind carbon copy recipients
   - Comma-separated email addresses
   
3. **Send in background**
   - Queue for async processing
   - Faster response
   - Works for both email and SMS

---

## Migration Notes

**No migration needed!** The changes are:
- ✅ Backend already supported optional from addresses
- ✅ Frontend now simply doesn't send them
- ✅ Settings hierarchy was already implemented
- ✅ Existing communications will continue to work

**Action items:**
1. Set platform-wide email/SMS from addresses (if not already set)
2. Optionally set per-company addresses for branding
3. Test sending quotes via email and SMS
4. Verify from addresses appear correctly

---

## Testing

### Test Email
```ruby
# Via console
CommunicationService.send_email(
  communicable: Quote.first,
  to: 'test@example.com',
  subject: 'Test',
  body: 'Test email'
)

# Check the from_address
Communication.last.from_address
# Should show: noreply@yourcompany.com (from settings)
```

### Test SMS
```ruby
# Via console
CommunicationService.send_sms(
  communicable: Quote.first,
  to: '+13035709810',
  body: 'Test SMS'
)

# Check the from_address
Communication.last.from_address
# Should show: +17205752095 (from settings)
```

### Test from UI
1. Open any quote
2. Click "Send Quote"
3. Select Email or SMS
4. Enter recipient
5. Click "Send Now"
6. ✅ Should work without entering from address!

---

## Future Enhancement

**User-specific from addresses:**
- Later, we'll wire up individual user email addresses
- Users can send from their own email
- Company settings will still be the default
- Per-user override will be highest priority

**Hierarchy will become:**
```
1. User email (future)
   ↓
2. Company settings
   ↓
3. Platform settings
   ↓
4. ENV variables
   ↓
5. Hardcoded defaults
```

---

## Files Modified

**Frontend:**
- `SendQuoteModal.tsx`
  - Removed fromEmail field
  - Removed fromPhone field
  - Removed from interface definition
  - Removed from form submission

**Backend:**
- `communication_service.rb`
  - Updated `default_from_address` method
  - Now uses settings service for both email and SMS
  - Unified approach for both channels

---

## Summary

✅ **UI simplified** - No more from address fields  
✅ **Settings hierarchy** - Company → Platform → ENV → Default  
✅ **Both channels** - Email and SMS use same approach  
✅ **Less confusion** - Users don't need to think about from addresses  
✅ **Centralized management** - Admins control from addresses  
✅ **Ready for future** - Easy to add user-specific emails later  

**From addresses now just work automatically!** 🎉

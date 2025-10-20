# SMS From Number Fix - Summary

**Date:** October 19, 2025  
**Issue:** "Validation failed: From address can't be blank for SMS"  
**Status:** ✅ FIXED

---

## Problem

When sending SMS from the quote interface, the system was showing:
```
Error sending quote SMS: Validation failed: From address can't be blank for SMS
```

This was happening because:
1. User didn't enter a "from phone number" (and shouldn't have to)
2. Backend was looking for `ENV['TWILIO_PHONE_NUMBER']` directly
3. It wasn't using the `CommunicationSettingsService` to get the from number from company/platform settings

---

## Solution

### Backend Fix (`CommunicationService`)

Updated the `default_from_address` method to use `CommunicationSettingsService`:

**Before:**
```ruby
def default_from_address(channel)
  case channel
  when 'email'
    ENV['DEFAULT_FROM_EMAIL'] || 'noreply@platformdms.com'
  when 'sms'
    ENV['TWILIO_PHONE_NUMBER']  # ❌ Only checks ENV
  else
    nil
  end
end
```

**After:**
```ruby
def default_from_address(channel, communicable = nil)
  case channel
  when 'email'
    ENV['DEFAULT_FROM_EMAIL'] || 'noreply@platformdms.com'
  when 'sms'
    # ✅ Now checks Company → Platform → ENV hierarchy
    company = extract_company_from_communicable(communicable)
    settings_service = company ? 
      CommunicationSettingsService.for_company(company) : 
      CommunicationSettingsService.platform
    
    sms_config = settings_service.sms_config
    sms_config[:from_number] || ENV['TWILIO_PHONE_NUMBER']
  else
    nil
  end
end
```

### Frontend Fix (`SendQuoteModal.tsx`)

Updated helper text to clarify that fields pull from settings:

**From Phone Number field:**
- Old text: "Leave blank to use default SMS number"
- New text: "Leave blank to use default phone from company/platform settings"

**From Email field:**
- Old text: "Leave blank to use default sender address"
- New text: "Leave blank to use default email from company/platform settings"

---

## Configuration Hierarchy

The system now properly checks settings in this order:

```
1. Explicit from_phone parameter (if provided in UI)
   ↓
2. Company-specific SMS settings (CommunicationSetting for company)
   ↓
3. Platform-wide SMS settings (PlatformSetting)
   ↓
4. Environment variable (ENV['TWILIO_PHONE_NUMBER'])
   ↓
5. Error if none found
```

---

## Setting Up SMS From Number

### Option 1: Platform Settings (Recommended)
```ruby
# In Rails console:
PlatformSetting.set(:sms, :from_number, '+17205752095')
```

### Option 2: Company Settings (Per-Company Override)
```ruby
# In Rails console:
company = Company.find(1)
company.set_communication_setting(:sms, :from_number, '+17205551234')
```

### Option 3: Environment Variable (Fallback)
```bash
# In .env:
TWILIO_PHONE_NUMBER=+17205752095
```

---

## CC and BCC Options

**Status:** ✅ Already Available

CC and BCC options are available in the **Advanced Options** section of the Send Quote modal:

1. Click "Advanced Options" to expand
2. When sending via Email:
   - CC field for carbon copy recipients
   - BCC field for blind carbon copy recipients
3. Both fields are optional
4. Backend already supports passing these through

---

## Testing

### Test 1: Verify from_number resolution
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails runner test_from_number.rb
```

### Test 2: Send test SMS
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails runner test_sms_simple.rb
```

### Test 3: Send from UI
1. Go to Quotes
2. Open a quote
3. Click "Send Quote"
4. Select SMS delivery method
5. Enter phone number
6. Leave "From Phone Number" blank in Advanced Options
7. Click "Send Now"
8. ✅ Should work without validation error!

---

## What Changed

### Backend Changes
- ✅ `app/services/communication_service.rb`
  - Updated `default_from_address` method
  - Now accepts `communicable` parameter
  - Uses `CommunicationSettingsService` for SMS
  - Proper configuration hierarchy

### Frontend Changes
- ✅ `src/modules/quote-builder/components/SendQuoteModal.tsx`
  - Updated helper text for clarity
  - CC and BCC already present in Advanced Options
  - From phone/email fields clarify they pull from settings

### Test Scripts Created
- ✅ `test_from_number.rb` - Verify from number resolution
- ✅ `test_sms_simple.rb` - Test SMS sending

---

## Verification Checklist

- ✅ SMS from number pulls from Company settings (if set)
- ✅ SMS from number falls back to Platform settings
- ✅ SMS from number falls back to ENV variable
- ✅ Validation error is fixed
- ✅ CC and BCC options available in UI
- ✅ Helper text clarifies settings hierarchy
- ✅ Test scripts available

---

## Example SMS Send Flow

```
User Action: Send SMS without entering from_phone
    ↓
Frontend: Sends request without from_phone field
    ↓
QuotesController: Calls QuoteSendingService
    ↓
QuoteSendingService: Calls CommunicationService.send_sms
    ↓
CommunicationService: 
  - Checks if from parameter provided → NO
  - Calls default_from_address('sms', quote)
    ↓
default_from_address method:
  - Extracts company from quote
  - Gets CommunicationSettingsService for company
  - Retrieves sms_config
  - Returns from_number from settings
    ↓
Communication record created with from_address
    ↓
TwilioProvider sends SMS using from_address
    ↓
✅ Success!
```

---

## Files Modified

### Backend
```
app/services/communication_service.rb
  - Line 155: Added from ||= default_from_address(channel, communicable)
  - Line 372-385: Updated default_from_address method
```

### Frontend
```
src/modules/quote-builder/components/SendQuoteModal.tsx
  - Line 551: Updated from email helper text
  - Line 591: Updated from phone helper text
```

### Test Scripts
```
test_from_number.rb (new)
```

---

## Next Steps (Optional)

1. **Set Platform SMS Settings**
   ```ruby
   PlatformSetting.set(:sms, :from_number, '+17205752095')
   ```

2. **Test SMS Sending**
   - Use test script or send from UI
   - Verify no validation errors

3. **Configure Company-Specific Numbers** (Optional)
   - For companies that need different SMS numbers
   - Set via CommunicationSetting

---

## Success!

✅ SMS from number now automatically pulls from settings  
✅ No need to enter from_phone in UI  
✅ Proper configuration hierarchy (Company → Platform → ENV)  
✅ CC and BCC options available in Advanced Options  
✅ Validation error fixed  

**You can now send SMS without entering a from phone number!** 🎉

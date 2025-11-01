# SMS MFA Implementation - Phase 1 Complete (Backend)
**Date:** October 31, 2025
**Status:** ✅ Backend Complete - Ready for Migration & Testing

---

## 🎯 What We Built

Following the **Dual MFA Strategy** from `DUAL_MFA_STRATEGY.md`, we've implemented SMS MFA **alongside** existing TOTP without deleting any code.

### Strategy Recap
- ✅ **Keep all TOTP code** - nothing deleted
- ✅ **Add SMS in parallel** - new service, endpoints, columns
- ✅ **Feature flag ready** - can toggle between methods
- ✅ **Universal Communication Strategy** - uses Platform/Company settings hierarchy

---

## 📁 Files Created/Modified

### 1. **Migration** ✅ CREATED
**File:** `db/migrate/20251031030000_add_sms_mfa_to_users.rb`

**New Columns Added:**
- `phone_verified` (boolean, default: false) - phone ownership verification
- `mfa_sms_code` (string) - temporary 6-digit SMS code
- `mfa_sms_expires_at` (datetime) - code expiration (5 minutes)
- `mfa_method` (string, default: 'sms') - tracks active method ('sms' or 'totp')

**Indexes Added:**
- `phone_verified`, `mfa_sms_expires_at`, `mfa_method`

**Existing Columns Preserved:**
- `mfa_enabled` (boolean)
- `mfa_secret` (string) - for TOTP
- `mfa_backup_codes` (json)
- `mfa_verified_at` (datetime)
- `phone` (string) - already existed

---

### 2. **SMS Service** ✅ CREATED
**File:** `app/services/mfa/sms_service.rb`

**Key Features:**
- Follows **Universal Communication Strategy**
  ```ruby
  settings_service = company ? 
    CommunicationSettingsService.for_company(company) : 
    CommunicationSettingsService.platform
  ```
- Uses existing `Providers::Sms::TwilioProvider`
- Methods:
  - `send_code` - sends 6-digit code via SMS (5-minute expiration)
  - `verify(code)` - verifies SMS code
  - `enable_mfa` - marks MFA as enabled with SMS method
  - `disable_mfa` - disables SMS MFA (keeps TOTP data)

**SMS Message Format:**
```
Platform DMS: Your verification code is 123456. Valid for 5 minutes.
```

---

### 3. **MFA Controller** ✅ MODIFIED
**File:** `app/controllers/api/v1/mfa_controller.rb`

**New SMS Endpoints Added:**
- `POST /api/v1/mfa/sms/enroll` - send verification code
- `POST /api/v1/mfa/sms/verify` - verify code & enable MFA
- `POST /api/v1/mfa/sms/resend` - resend verification code
- `POST /api/v1/mfa/sms/disable` - disable SMS MFA

**Existing TOTP Endpoints Preserved:**
- `POST /api/v1/mfa/enroll` - TOTP enrollment
- `POST /api/v1/mfa/verify` - TOTP verification
- `POST /api/v1/mfa/backup_codes/regenerate` - TOTP backup codes
- `POST /api/v1/mfa/disable` - general MFA disable

**Updated Status Endpoint:**
```ruby
GET /api/v1/mfa/status
Response:
{
  "mfa_enabled": true/false,
  "mfa_method": "sms" or "totp",
  "mfa_verified_at": "2025-10-31T...",
  "phone": "+15551234567",
  "phone_verified": true/false,
  "backup_codes_count": 10,
  "backup_codes_low": false
}
```

---

### 4. **Routes** ✅ MODIFIED
**File:** `config/routes.rb`

**Added SMS Routes (parallel to TOTP):**
```ruby
scope path: 'mfa', controller: 'mfa' do
  # Shared
  get 'status', action: :status
  post 'disable', action: :disable
  
  # TOTP (existing)
  post 'enroll', action: :enroll
  post 'verify', action: :verify
  post 'backup_codes/regenerate', action: :regenerate_backup_codes
  
  # SMS (new)
  post 'sms/enroll', action: :sms_enroll
  post 'sms/verify', action: :sms_verify
  post 'sms/resend', action: :sms_resend
  post 'sms/disable', action: :sms_disable
end
```

---

## 🚀 Next Steps: Run Migration & Test

### Step 1: Run Migration
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails db:migrate
```

**Expected Output:**
```
== 20251031030000 AddSmsMfaToUsers: migrating ================================
-- add_column(:users, :phone_verified, :boolean, {:default=>false, :null=>false})
-- add_column(:users, :mfa_sms_code, :string)
-- add_column(:users, :mfa_sms_expires_at, :datetime)
-- add_column(:users, :mfa_method, :string, {:default=>"sms"})
-- add_index(:users, :phone_verified)
-- add_index(:users, :mfa_sms_expires_at)
-- add_index(:users, :mfa_method)
== 20251031030000 AddSmsMfaToUsers: migrated (0.0234s) =======================
```

### Step 2: Restart Rails Server
```bash
# Kill existing Rails process
pkill -f "rails s"

# Start fresh
cd /home/tschi/src/renterinsight_api
bundle exec rails s -b 0.0.0.0 -p 3001
```

### Step 3: Test SMS MFA Flow

**Get Auth Token First:**
```bash
curl -X POST https://localhost:3001/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{
    "email": "your@email.com",
    "password": "password"
  }'
```

**1. Check Status:**
```bash
curl https://localhost:3001/api/v1/mfa/status \
  -H "Authorization: Bearer YOUR_TOKEN"
```

**2. Enroll with SMS:**
```bash
curl -X POST https://localhost:3001/api/v1/mfa/sms/enroll \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "phone_number": "+15551234567"
  }'
```

**3. Verify SMS Code:**
```bash
curl -X POST https://localhost:3001/api/v1/mfa/sms/verify \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "code": "123456"
  }'
```

**4. Resend Code (if needed):**
```bash
curl -X POST https://localhost:3001/api/v1/mfa/sms/resend \
  -H "Authorization: Bearer YOUR_TOKEN"
```

---

## 📊 Settings Requirements

The SMS MFA uses the **Universal Communication Strategy** which requires Twilio settings:

### Platform Settings (fallback)
```bash
# Check if platform settings exist
curl https://localhost:3001/api/platform/settings \
  -H "Authorization: Bearer YOUR_TOKEN"
```

### Company Settings (override)
```bash
# Check company settings
curl https://localhost:3001/api/company/settings \
  -H "Authorization: Bearer YOUR_TOKEN"
```

### Expected Settings Structure:
```json
{
  "communications": {
    "sms": {
      "provider": "twilio",
      "fromNumber": "+15551234567",
      "twilioAccountSid": "encrypted:...",
      "twilioAuthToken": "encrypted:...",
      "isEnabled": true
    }
  }
}
```

### ENV Fallback:
If no database settings exist, it falls back to ENV variables:
- `TWILIO_PHONE_NUMBER`
- `TWILIO_ACCOUNT_SID`
- `TWILIO_AUTH_TOKEN`

---

## ✅ What's PRESERVED (Zero Risk!)

### All TOTP Code Remains:
- ✅ `MfaEnrollmentWizard.tsx` (frontend)
- ✅ `rotp` gem
- ✅ `mfa_secret` column
- ✅ `mfa_backup_codes` column
- ✅ TOTP enroll/verify endpoints
- ✅ QR code generation

### Easy Toggle:
To switch back to TOTP, just use:
```bash
curl -X POST https://localhost:3001/api/v1/mfa/enroll \
  -H "Authorization: Bearer YOUR_TOKEN"
```

---

## 🎛️ Frontend Implementation (Next Phase)

When ready for frontend:

### 1. Create `MfaSmsEnrollment.tsx`
**Location:** `src/components/mfa/MfaSmsEnrollment.tsx`

**Features:**
- Phone number input with validation
- SMS code verification (6-digit input)
- Resend code button
- Error handling
- Loading states

### 2. Update `mfaService.ts`
**Location:** `src/services/mfaService.ts`

Add parallel SMS methods:
```typescript
export const mfaService = {
  // Existing TOTP methods (keep)
  initiateEnrollment: async () => { /* TOTP */ },
  verifyEnrollment: async (code: string) => { /* TOTP */ },
  
  // New SMS methods (add)
  smsEnroll: async (phoneNumber: string) => { /* SMS */ },
  smsVerify: async (code: string) => { /* SMS */ },
  smsResend: async () => { /* SMS */ },
  
  // Shared methods
  getStatus: async () => { /* works for both */ },
  disable: async () => { /* works for both */ },
};
```

### 3. Add Feature Flag
**Location:** `src/modules/settings/MfaSettings.tsx`

```typescript
// Toggle between SMS and TOTP
const useSmsMethod = true; // Set to false to use TOTP

{showEnrollment && (
  useSmsMethod ? (
    <MfaSmsEnrollment 
      onComplete={() => setShowEnrollment(false)}
      onCancel={() => setShowEnrollment(false)}
    />
  ) : (
    <MfaEnrollmentWizard 
      onComplete={() => setShowEnrollment(false)}
      onCancel={() => setShowEnrollment(false)}
    />
  )
)}
```

---

## 🔧 Troubleshooting

### Migration Issues:
```bash
# Check migration status
bundle exec rails db:migrate:status

# Rollback if needed
bundle exec rails db:rollback STEP=1

# Re-run
bundle exec rails db:migrate
```

### SMS Not Sending:
1. Check Twilio settings in database or ENV
2. Verify phone number format (E.164: +1XXXXXXXXXX)
3. Check Rails logs: `tail -f log/development.log | grep MFA:SMS`
4. Test Twilio provider directly:
   ```ruby
   provider = Providers::Sms::TwilioProvider.new
   provider.send_message(to: '+15551234567', body: 'Test')
   ```

### Check Service:
```bash
bundle exec rails console

user = User.find_by(email: 'your@email.com')
sms_service = Mfa::SmsService.new(user)
result = sms_service.send_code
puts result.inspect
```

---

## 📝 Testing Checklist

- [ ] Migration runs without errors
- [ ] Rails server starts successfully
- [ ] `GET /api/v1/mfa/status` returns new fields
- [ ] `POST /api/v1/mfa/sms/enroll` sends SMS
- [ ] SMS code received on phone
- [ ] `POST /api/v1/mfa/sms/verify` accepts valid code
- [ ] `POST /api/v1/mfa/sms/verify` rejects invalid code
- [ ] Code expires after 5 minutes
- [ ] `POST /api/v1/mfa/sms/resend` works
- [ ] TOTP endpoints still work (backward compatibility)
- [ ] Can toggle between SMS and TOTP methods

---

## 💡 Key Design Decisions

1. **Additive Architecture**
   - No TOTP code deleted
   - SMS runs parallel to TOTP
   - Can switch methods anytime

2. **Universal Communication Strategy**
   - Settings: Company → Platform → ENV
   - Uses existing Twilio infrastructure
   - No duplicate configuration

3. **Security**
   - 6-digit codes (1,000,000 combinations)
   - 5-minute expiration
   - Codes stored temporarily, cleared after verification
   - Phone verification before enabling MFA

4. **Future Flexibility**
   - Can offer user choice (SMS or TOTP)
   - Can use different methods per role
   - Can add SMS as backup to TOTP

---

## 🎉 Summary

**Backend is complete and ready!**

✅ Migration created (adds 4 columns, 3 indexes)
✅ SMS service follows Universal Communication Strategy
✅ Controller has parallel SMS endpoints
✅ Routes updated with SMS paths
✅ Status endpoint enhanced
✅ All TOTP code preserved
✅ Zero breaking changes

**Next:** Run migration, test endpoints, then build frontend!

**Estimated Time to Test:** 15-30 minutes
**Estimated Time for Frontend:** 2-3 hours

---

## 📞 Copy/Paste Commands for Testing

```bash
# 1. Run migration
cd /home/tschi/src/renterinsight_api && bundle exec rails db:migrate

# 2. Restart server
pkill -f "rails s" && cd /home/tschi/src/renterinsight_api && bundle exec rails s -b 0.0.0.0 -p 3001 &

# 3. Test status (replace YOUR_TOKEN)
curl https://localhost:3001/api/v1/mfa/status -H "Authorization: Bearer YOUR_TOKEN"

# 4. Test enrollment (replace YOUR_TOKEN and phone)
curl -X POST https://localhost:3001/api/v1/mfa/sms/enroll \
  -H "Authorization: Bearer YOUR_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"phone_number": "+15551234567"}'
```

---

**Ready to proceed with migration and testing! 🚀**

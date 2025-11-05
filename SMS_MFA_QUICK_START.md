# SMS MFA - Quick Start for Next Session
**Status:** Backend Complete | Ready for Migration & Testing

---

## 📋 What Was Done (Phase 1 - Backend)

✅ **Migration Created:** `db/migrate/20251031030000_add_sms_mfa_to_users.rb`
- Added 4 columns: `phone_verified`, `mfa_sms_code`, `mfa_sms_expires_at`, `mfa_method`
- Added 3 indexes for performance

✅ **Service Created:** `app/services/mfa/sms_service.rb`
- Follows Universal Communication Strategy (Company → Platform → ENV)
- Methods: `send_code`, `verify`, `enable_mfa`, `disable_mfa`

✅ **Controller Updated:** `app/controllers/api/v1/mfa_controller.rb`
- Added 4 SMS endpoints (parallel to TOTP)
- Updated status endpoint with SMS fields

✅ **Routes Updated:** `config/routes.rb`
- Added SMS routes alongside TOTP routes

✅ **All TOTP Code Preserved:** Zero breaking changes

---

## 🚀 Next Steps (15 min)

### Step 1: Run Migration
```bash
cd /home/tschi/src/renterinsight_api
bundle exec rails db:migrate
```

### Step 2: Restart Rails Server
```bash
pkill -f "rails s"
cd /home/tschi/src/renterinsight_api
bundle exec rails s -b 0.0.0.0 -p 3001
```

### Step 3: Test SMS Enrollment
```bash
# Get token first
TOKEN=$(curl -s -X POST https://localhost:3001/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"password"}' \
  | jq -r '.token')

# Check status
curl https://localhost:3001/api/v1/mfa/status \
  -H "Authorization: Bearer $TOKEN"

# Enroll with SMS (replace phone number)
curl -X POST https://localhost:3001/api/v1/mfa/sms/enroll \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"phone_number": "+15551234567"}'

# Check your phone for the code, then verify
curl -X POST https://localhost:3001/api/v1/mfa/sms/verify \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"code": "123456"}'
```

---

## 📝 New API Endpoints

### SMS MFA Endpoints (NEW)
- `POST /api/v1/mfa/sms/enroll` - send verification code to phone
- `POST /api/v1/mfa/sms/verify` - verify code & enable SMS MFA
- `POST /api/v1/mfa/sms/resend` - resend verification code
- `POST /api/v1/mfa/sms/disable` - disable SMS MFA

### Updated Endpoint
- `GET /api/v1/mfa/status` - now returns `mfa_method`, `phone`, `phone_verified`

### TOTP Endpoints (PRESERVED)
- `POST /api/v1/mfa/enroll` - TOTP enrollment (unchanged)
- `POST /api/v1/mfa/verify` - TOTP verification (unchanged)
- `POST /api/v1/mfa/backup_codes/regenerate` - TOTP backup codes (unchanged)

---

## 🎯 After Testing Backend: Frontend Phase

### Files to Create/Update:
1. `src/components/mfa/MfaSmsEnrollment.tsx` (NEW)
2. `src/services/mfaService.ts` (ADD SMS methods)
3. `src/modules/settings/MfaSettings.tsx` (ADD feature flag)

### Feature Flag Pattern:
```typescript
const useSmsMethod = true; // Toggle: true = SMS, false = TOTP
```

---

## 📁 Reference Documents

- **Full Implementation:** `SMS_MFA_BACKEND_COMPLETE.md`
- **Strategy Document:** `DUAL_MFA_STRATEGY.md`
- **SMS Testing Checklist:** See "Testing Checklist" in complete doc

---

## 🔧 Quick Troubleshooting

**Migration fails?**
```bash
bundle exec rails db:rollback STEP=1
bundle exec rails db:migrate
```

**SMS not sending?**
- Check Twilio settings in Platform/Company settings
- Verify phone format: +1XXXXXXXXXX (E.164)
- Check logs: `tail -f log/development.log | grep MFA:SMS`

**Test in console:**
```bash
bundle exec rails console
user = User.first
service = Mfa::SmsService.new(user)
service.send_code
```

---

## 💡 Key Architecture Points

1. **Parallel Implementation:** SMS runs alongside TOTP (nothing deleted)
2. **Universal Settings:** Uses existing Twilio infrastructure
3. **Feature Flag Ready:** Easy toggle between SMS/TOTP
4. **Backward Compatible:** All TOTP endpoints unchanged

---

## ✅ Success Criteria

Backend is ready when:
- [ ] Migration completes without errors
- [ ] Rails server starts successfully  
- [ ] SMS code arrives on phone
- [ ] Code verification works
- [ ] TOTP endpoints still function (backward compatibility)

---

**Ready to run migration and test! 🚀**

**Time Estimate:** 15-30 minutes for testing
**Next Phase:** Frontend implementation (2-3 hours)

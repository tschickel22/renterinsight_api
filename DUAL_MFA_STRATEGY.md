# Dual MFA Strategy: SMS Primary + TOTP Hidden
**Date:** October 31, 2025
**Strategy:** Build SMS MFA alongside existing TOTP, don't delete anything

---

## 🎯 Smart Strategy: Keep Both, Show SMS

### Why This Approach is Better
- ✅ **No risk**: Don't delete working code (even if buggy)
- ✅ **Flexibility**: Can enable TOTP later for enterprise customers
- ✅ **A/B testing**: Test which method users prefer
- ✅ **Fallback**: If SMS has issues, switch back to TOTP
- ✅ **Options**: Offer user choice later ("Choose your MFA method")
- ✅ **Security tiers**: SMS for basic, TOTP for sensitive roles

### Implementation (2-3 hours)
1. **Keep all TOTP code** - don't delete anything
2. **Add SMS alongside** - new service, new endpoints
3. **Hide TOTP UI** - conditional rendering in frontend
4. **Feature flag** - easy toggle in admin or ENV var

---

## 📋 What to DO (Not Delete!)

### Backend: ADD New Code (Keep Existing)

#### Step 1: Add Twilio Gem (Keep ROTP)
```ruby
# Gemfile - ADD this line (don't remove rotp)
gem 'rotp'  # Keep for TOTP
gem 'twilio-ruby', '~> 6.0'  # Add for SMS
```

#### Step 2: Database Migration (Additive)
```ruby
# db/migrate/[timestamp]_add_sms_mfa_to_users.rb
class AddSmsMfaToUsers < ActiveRecord::Migration[7.0]
  def change
    # Add SMS-specific columns (keep existing TOTP columns)
    add_column :users, :phone_number, :string
    add_column :users, :phone_verified, :boolean, default: false
    add_column :users, :mfa_sms_code, :string
    add_column :users, :mfa_sms_expires_at, :datetime
    add_column :users, :mfa_method, :string, default: 'sms' # 'sms' or 'totp'
    
    # Keep existing:
    # - mfa_enabled
    # - mfa_verified_at
    # - mfa_secret (for TOTP)
    # - mfa_backup_codes
  end
end
```

#### Step 3: Create SMS Service (Parallel to TOTP)
```ruby
# app/services/mfa/sms_service.rb (NEW FILE)
module Mfa
  class SmsService
    def initialize(user)
      @user = user
      @client = Twilio::REST::Client.new(
        Rails.application.credentials.twilio[:account_sid],
        Rails.application.credentials.twilio[:auth_token]
      )
    end

    def send_code
      code = sprintf('%06d', SecureRandom.random_number(1_000_000))
      
      @user.update!(
        mfa_sms_code: code,
        mfa_sms_expires_at: 5.minutes.from_now
      )
      
      @client.messages.create(
        from: Rails.application.credentials.twilio[:phone_number],
        to: @user.phone_number,
        body: "Platform DMS: #{code} (expires in 5 min)"
      )
      
      Rails.logger.info "SMS sent to #{@user.phone_number}"
      true
    rescue => e
      Rails.logger.error "SMS failed: #{e.message}"
      false
    end

    def verify(code)
      return false if @user.mfa_sms_code.blank?
      return false if @user.mfa_sms_expires_at < Time.current
      
      if @user.mfa_sms_code == code
        @user.update!(mfa_sms_code: nil, mfa_sms_expires_at: nil)
        true
      else
        false
      end
    end
  end
end
```

#### Step 4: Add SMS Endpoints (Keep TOTP Endpoints)
```ruby
# app/controllers/api/v1/mfa_controller.rb
# ADD these methods, KEEP existing TOTP methods

# POST /api/v1/mfa/sms/enroll
def sms_enroll
  phone = params[:phone_number]
  
  if phone.blank?
    return render json: { error: 'Phone number required' }, status: :unprocessable_entity
  end
  
  current_user.update!(phone_number: phone, mfa_method: 'sms')
  sms_service = Mfa::SmsService.new(current_user)
  
  if sms_service.send_code
    render json: { message: 'Code sent' }
  else
    render json: { error: 'Failed to send SMS' }, status: :unprocessable_entity
  end
end

# POST /api/v1/mfa/sms/verify
def sms_verify
  code = params[:code]
  sms_service = Mfa::SmsService.new(current_user)
  
  if sms_service.verify(code)
    current_user.update!(
      mfa_enabled: true,
      mfa_verified_at: Time.current,
      mfa_method: 'sms'
    )
    
    render json: { message: 'MFA enabled' }
  else
    render json: { error: 'Invalid code' }, status: :unprocessable_entity
  end
end

# Keep existing:
# - enroll (TOTP)
# - verify (TOTP)
# - disable
# - status
```

#### Step 5: Update Routes
```ruby
# config/routes.rb
namespace :api do
  namespace :v1 do
    # Keep existing TOTP routes
    post 'mfa/enroll', to: 'mfa#enroll'
    post 'mfa/verify', to: 'mfa#verify'
    
    # Add SMS routes
    post 'mfa/sms/enroll', to: 'mfa#sms_enroll'
    post 'mfa/sms/verify', to: 'mfa#sms_verify'
    post 'mfa/sms/resend', to: 'mfa#sms_resend'
    
    # Shared routes
    post 'mfa/disable', to: 'mfa#disable'
    get 'mfa/status', to: 'mfa#status'
  end
end
```

### Frontend: ADD New Code (Hide Existing)

#### Step 1: Create Simple SMS Component
```tsx
// src/components/mfa/MfaSmsEnrollment.tsx (NEW FILE)
import React, { useState } from 'react';
import { MfaVerificationInput } from './MfaVerificationInput';

export const MfaSmsEnrollment: React.FC<{
  onComplete: () => void;
  onCancel: () => void;
}> = ({ onComplete, onCancel }) => {
  const [step, setStep] = useState<'phone' | 'verify'>('phone');
  const [phone, setPhone] = useState('');
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  const sendCode = async () => {
    setLoading(true);
    setError('');
    
    try {
      await mfaService.smsEnroll(phone);
      setStep('verify');
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  const verifyCode = async (code: string) => {
    setLoading(true);
    setError('');
    
    try {
      await mfaService.smsVerify(code);
      onComplete();
    } catch (err: any) {
      setError(err.message);
    } finally {
      setLoading(false);
    }
  };

  if (step === 'phone') {
    return (
      <div className="space-y-4">
        <h2 className="text-xl font-bold">Enable SMS MFA</h2>
        <p className="text-gray-600">
          We'll send a verification code to your phone
        </p>
        
        <input
          type="tel"
          value={phone}
          onChange={(e) => setPhone(e.target.value)}
          placeholder="+1 (555) 123-4567"
          className="w-full px-4 py-2 border rounded"
        />
        
        {error && <p className="text-red-600">{error}</p>}
        
        <div className="flex gap-2">
          <button onClick={sendCode} disabled={loading}>
            Send Code
          </button>
          <button onClick={onCancel}>Cancel</button>
        </div>
      </div>
    );
  }

  return (
    <div className="space-y-4">
      <h2 className="text-xl font-bold">Enter Verification Code</h2>
      <p className="text-gray-600">
        Check your phone for a 6-digit code
      </p>
      
      <MfaVerificationInput
        onChange={verifyCode}
        error={error}
        autoFocus
      />
      
      <button onClick={() => setStep('phone')}>Back</button>
    </div>
  );
};
```

#### Step 2: Add SMS Methods to Service
```typescript
// src/services/mfaService.ts
// ADD these methods, KEEP existing TOTP methods

export const mfaService = {
  // Keep existing TOTP methods:
  initiateEnrollment: async () => { /* TOTP */ },
  verifyEnrollment: async (code: string) => { /* TOTP */ },
  
  // Add SMS methods:
  smsEnroll: async (phoneNumber: string) => {
    const response = await apiClient.post('/api/v1/mfa/sms/enroll', { 
      phone_number: phoneNumber 
    });
    return response.data;
  },
  
  smsVerify: async (code: string) => {
    const response = await apiClient.post('/api/v1/mfa/sms/verify', { code });
    return response.data;
  },
  
  smsResend: async () => {
    const response = await apiClient.post('/api/v1/mfa/sms/resend');
    return response.data;
  },
  
  // Shared methods (work for both):
  getStatus: async () => { /* ... */ },
  disable: async (code: string) => { /* ... */ },
};
```

#### Step 3: Update MfaSettings to Show SMS
```tsx
// src/modules/settings/MfaSettings.tsx
// MODIFY to conditionally render SMS or TOTP

import { MfaSmsEnrollment } from '../../components/mfa/MfaSmsEnrollment';
import { MfaEnrollmentWizard } from '../../components/mfa/MfaEnrollmentWizard';

const MfaSettings = () => {
  const [showEnrollment, setShowEnrollment] = useState(false);
  
  // Feature flag - change this to switch between SMS and TOTP
  const useSmsMethod = true; // Set to false to use TOTP

  return (
    <div>
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
    </div>
  );
};
```

---

## 🎛️ Feature Flag Options

### Option 1: Frontend Constant (Quick)
```typescript
// src/config/features.ts
export const FEATURES = {
  MFA_METHOD: 'sms' as 'sms' | 'totp' | 'both'
};
```

### Option 2: Environment Variable (Better)
```bash
# .env
VITE_MFA_METHOD=sms  # or 'totp' or 'both'
```

### Option 3: Backend Setting (Best)
```ruby
# Add to companies table or settings
company.settings[:mfa_method] = 'sms' # or 'totp' or 'both'
```

### Option 4: User Choice (Ultimate)
```tsx
// Let users pick their method
<select>
  <option value="sms">SMS (Text Message)</option>
  <option value="totp">Authenticator App</option>
</select>
```

---

## 📊 Comparison: What You Keep vs What You Add

| Component | TOTP (Keep Hidden) | SMS (Add & Show) |
|-----------|-------------------|------------------|
| **Backend Gem** | ✅ rotp | ➕ twilio-ruby |
| **Service** | ✅ MfaController#enroll/verify | ➕ Mfa::SmsService |
| **Endpoints** | ✅ /mfa/enroll, /mfa/verify | ➕ /mfa/sms/enroll, /mfa/sms/verify |
| **DB Columns** | ✅ mfa_secret, mfa_backup_codes | ➕ phone_number, mfa_sms_code |
| **Frontend UI** | ✅ MfaEnrollmentWizard (hide) | ➕ MfaSmsEnrollment (show) |
| **Service Methods** | ✅ initiateEnrollment(), verifyEnrollment() | ➕ smsEnroll(), smsVerify() |

---

## 🚀 Implementation Steps (2-3 hours)

### Phase 1: Backend Setup (1 hour)
1. ✅ Add `twilio-ruby` to Gemfile (keep `rotp`)
2. ✅ Run `bundle install`
3. ✅ Create database migration (additive)
4. ✅ Run `rails db:migrate`
5. ✅ Create `app/services/mfa/sms_service.rb`
6. ✅ Add SMS methods to `MfaController`
7. ✅ Update routes
8. ✅ Add Twilio credentials to Rails credentials

### Phase 2: Frontend Setup (1 hour)
1. ✅ Create `MfaSmsEnrollment.tsx`
2. ✅ Add SMS methods to `mfaService.ts`
3. ✅ Add feature flag constant
4. ✅ Update `MfaSettings.tsx` with conditional rendering
5. ✅ Test SMS flow

### Phase 3: Testing (30 minutes)
1. ✅ Test SMS enrollment
2. ✅ Test SMS login
3. ✅ Verify TOTP still works (toggle flag)
4. ✅ Test switching between methods

---

## 🎯 Future Options

Once both are working, you can:

### Option A: SMS Only (Current Plan)
- Set `useSmsMethod = true`
- TOTP code stays but UI is hidden

### Option B: User Choice
- Add "Choose MFA Method" screen
- Let users pick SMS or TOTP
- Support both simultaneously

### Option C: Tiered Approach
- Basic users: SMS only
- Admin users: TOTP only
- Enterprise: Choice of both

### Option D: Fallback
- Primary: SMS
- Backup: TOTP (if SMS fails)

---

## 💰 Cost with Dual Approach

**No additional cost!** You're only charged for SMS actually sent:
- SMS MFA active: ~$0.01 per login
- TOTP ready: $0 (code sits unused)
- Can switch anytime without changing code

---

## 🔧 Quick Toggle Guide

To switch between SMS and TOTP:

```tsx
// In MfaSettings.tsx, change one line:
const useSmsMethod = true;  // Show SMS
const useSmsMethod = false; // Show TOTP
```

That's it! Everything else works automatically.

---

## 📝 Summary

**What You're NOT Doing:**
- ❌ Deleting MfaEnrollmentWizard.tsx
- ❌ Removing ROTP gem
- ❌ Dropping TOTP database columns
- ❌ Removing TOTP endpoints

**What You ARE Doing:**
- ✅ Adding SMS service alongside TOTP
- ✅ Adding SMS UI alongside TOTP UI
- ✅ Adding feature flag to choose
- ✅ Defaulting to SMS (better UX)

**Result:** 
- Best of both worlds
- Zero risk
- Easy to toggle
- Can offer user choice later

---

## 🚀 Copy/Paste for Next Chat

```
Build SMS MFA ALONGSIDE existing TOTP (don't delete anything). Read:
- DUAL_MFA_STRATEGY.md (in backend root directory)

Strategy:
1. Keep all TOTP code (don't touch it)
2. Add SMS service, endpoints, and UI
3. Add feature flag to switch between them
4. Default to SMS, keep TOTP hidden

You have full access via extensions and we're testing on https.

Start by:
1. Adding twilio-ruby gem (keep rotp)
2. Creating additive database migration
3. Building Mfa::SmsService (new file)
4. Adding SMS endpoints to MfaController (keep TOTP endpoints)
5. Creating MfaSmsEnrollment.tsx (keep MfaEnrollmentWizard.tsx)
```

---

**This approach is MUCH smarter!** You keep all your work and can debug TOTP later without pressure. 🎉

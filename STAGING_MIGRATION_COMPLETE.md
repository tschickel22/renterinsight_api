# Staging Migration - Complete Configuration ✅

## Date: October 26, 2025

## Changes Made

### 1. Backend .env File Updated ✅
**File:** `/home/tschi/src/renterinsight_api/.env`

**Change:**
```bash
# OLD (Local Development):
FRONTEND_URL=http://localhost:3001

# NEW (Staging):
FRONTEND_URL=https://platform-dms-staging.netlify.app
```

### 2. Frontend .env File Already Updated ✅
**File:** `C:\Users\tschi\src\Platform_DMS_8.4.25\Platform_DMS_8.4.25\.env`

**Configuration:**
```bash
VITE_RAILS_API_URL=https://renterinsight-api-staging.onrender.com
REACT_APP_API_URL=https://renterinsight-api-staging.onrender.com/api
```

## Verified: No Hardcoded localhost:3001 References

### Backend Verification ✅
Searched all backend files for hardcoded `localhost:3001` references:
- **app/** directory: ✅ No hardcoded references found
- **config/** directory: ✅ No hardcoded references found

### Critical Files Using ENV Variables Correctly:

#### 1. Password Reset Service ✅
**File:** `app/services/password_reset_service.rb`
```ruby
def generate_reset_url(token)
  # Get frontend URL from ENV or default
  frontend_url = ENV['FRONTEND_URL'] || 'http://localhost:5173'
  "#{frontend_url}/reset-password?token=#{token}"
end
```

#### 2. Magic Link Mailer ✅
**File:** `app/mailers/magic_link_mailer.rb`
```ruby
def admin_magic_link(user, token)
  # ...
  frontend_url = ENV['FRONTEND_URL'] || 'http://localhost:5173'
  @magic_link = "#{frontend_url}/magic-link?token=#{token}"
  # ...
end
```

#### 3. Buyer Portal Mailer ✅
**File:** `app/mailers/buyer_portal_mailer.rb`
```ruby
def magic_link_email(buyer_access)
  # ...
  frontend_url = ENV['FRONTEND_URL'] || 'http://localhost:5173'
  @magic_link = "#{frontend_url}/magic-link?token=#{buyer_access.login_token}"
  # ...
end
```

#### 4. Password Reset Mailer ✅
**File:** `app/mailers/password_reset_mailer.rb`
- Uses `@reset_url` variable passed from service (no hardcoding)

#### 5. Email Templates ✅
**Files:**
- `app/views/password_reset_mailer/reset_instructions.html.erb`
- `app/views/password_reset_mailer/reset_instructions.text.erb`

Both templates use `<%= @reset_url %>` which is dynamically generated from ENV['FRONTEND_URL']

## Frontend Configuration

### Platform Settings Components Updated ✅

#### 1. EmailSettings.tsx
```typescript
// OLD (Hardcoded):
const API_BASE_URL = 'http://localhost:3001/api'

// NEW (Dynamic):
const API_BASE_URL = `${import.meta.env.VITE_RAILS_API_URL}/api`
```

#### 2. SmsSettings.tsx
```typescript
// OLD (Hardcoded):
const API_BASE_URL = 'http://localhost:3001/api'

// NEW (Dynamic):
const API_BASE_URL = `${import.meta.env.VITE_RAILS_API_URL}/api`
```

## Unified Communication Platform Integration ✅

### Backend Controllers
All properly use `CommunicationSettingsService` to fetch settings from database:

1. **ContactCommunicationsController** (`app/controllers/api/v1/contact_communications_controller.rb`)
   - Endpoints: `/api/v1/contacts/:contact_id/communications/email`
   - Endpoints: `/api/v1/contacts/:contact_id/communications/sms`

2. **AccountCommunicationsController** (`app/controllers/api/v1/account_communications_controller.rb`)
   - Endpoints: `/api/v1/accounts/:account_id/communications/email`
   - Endpoints: `/api/v1/accounts/:account_id/communications/sms`

3. **CRM::CommunicationsController** (`app/controllers/api/crm/communications_controller.rb`)
   - Endpoints: `/api/crm/leads/:lead_id/communications/email`
   - Endpoints: `/api/crm/leads/:lead_id/communications/sms`

### Frontend Integration
`CommunicationCenter` component integrated in all three modules:

1. **Contacts** (`src/modules/contacts/pages/ContactDetail.tsx`)
   ```tsx
   <CommunicationCenter 
     entityType="contact"
     entityId={String(contact.id)} 
     entityData={contact}
   />
   ```

2. **Accounts** (`src/modules/accounts/pages/AccountDetail.tsx`)
   ```tsx
   <CommunicationCenter 
     entityType="account"
     entityId={String(account.id)} 
     entityData={account}
   />
   ```

3. **Leads** (`src/modules/crm-prospecting/CRMProspecting.tsx`)
   ```tsx
   <CommunicationCenter 
     entityType="lead"
     entityId={leadId} 
     entityData={selectedLead}
   />
   ```

## Communication Settings Flow

### How It Works:
1. **Configure Settings:**
   - Navigate to Platform Settings → Communication tab
   - Configure Email (SMTP, Gmail, SendGrid, AWS SES)
   - Configure SMS (Twilio)
   - Settings are encrypted and stored in database

2. **Send Communication:**
   - User sends email/SMS from Lead/Contact/Account detail page
   - Frontend calls backend API endpoint
   - Backend fetches settings from database via `CommunicationSettingsService`
   - Settings are decrypted and used to configure provider
   - Email/SMS sent via configured provider

3. **Settings Priority:**
   - Company Settings (if available) → Platform Settings → ENV fallback

## Next Steps

### 1. Restart Backend on Render
The backend needs to pick up the new `FRONTEND_URL` environment variable:
- Go to Render dashboard
- Select your backend service
- Click "Manual Deploy" → "Clear build cache & deploy"

### 2. Test Password Reset Flow
1. Go to staging frontend: https://platform-dms-staging.netlify.app
2. Click "Forgot Password"
3. Enter your email
4. Check email - link should point to `https://platform-dms-staging.netlify.app/reset-password?token=...`
5. Complete password reset

### 3. Test Magic Link Login
1. Request magic link from login page
2. Check email - link should point to `https://platform-dms-staging.netlify.app/magic-link?token=...`
3. Click link and verify login works

### 4. Test Communication Platform
1. Configure Email/SMS settings in Platform Settings
2. Navigate to a Lead, Contact, or Account
3. Click Communication tab
4. Send test email/SMS
5. Verify message is received

## Environment Variables Summary

### Backend (.env)
```bash
FRONTEND_URL=https://platform-dms-staging.netlify.app
MAILER_FROM=noreply@renterinsight.com
JWT_SECRET=phase5a-unified-login-secret-key-change-in-production-abc123xyz
JWT_REFRESH_SECRET=phase5a-refresh-token-secret-key-change-in-production-def456uvw
```

### Frontend (.env)
```bash
VITE_RAILS_API_URL=https://renterinsight-api-staging.onrender.com
REACT_APP_API_URL=https://renterinsight-api-staging.onrender.com/api
```

## Verification Checklist

- ✅ Backend .env updated with staging frontend URL
- ✅ Frontend .env already configured with staging backend URL
- ✅ No hardcoded localhost:3001 references in backend
- ✅ No hardcoded localhost:3001 references in frontend Platform Settings
- ✅ Password reset uses ENV['FRONTEND_URL']
- ✅ Magic link uses ENV['FRONTEND_URL']
- ✅ All email templates use dynamic @reset_url / @magic_link
- ✅ Communication platform integrated in Leads, Contacts, Accounts
- ✅ All communication controllers use settings from database

## Status: READY FOR STAGING ✅

All configuration complete. Backend restart required to pick up new FRONTEND_URL.

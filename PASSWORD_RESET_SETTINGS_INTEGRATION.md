# 🎉 Password Reset System - COMPLETE INTEGRATION GUIDE

## ✅ What's Integrated

The password reset system is now **fully integrated** with your Platform Settings and Company Settings infrastructure!

### 🔧 System Components

1. **✅ Settings Integration**
   - Reads from Platform Settings (global defaults)
   - Reads from Company Settings (company-specific overrides)
   - Falls back to ENV variables (development/testing)
   - Cascading priority: Company → Platform → ENV

2. **✅ Email Support**
   - Professional HTML email templates
   - SMTP configuration via settings
   - From email/name customization
   - Secure token delivery

3. **✅ SMS Support**
   - 6-digit code generation
   - Twilio integration via settings
   - Phone number lookup for both admins and clients
   - 15-minute expiration

4. **✅ Database**
   - `password_reset_tokens` table with all features
   - `phone` field added to Users table
   - Full indexing for performance
   - Token expiration and usage tracking

5. **✅ Services**
   - `PasswordResetService` - Main business logic
   - `SmsService` - SMS delivery with settings
   - `PasswordResetMailer` - Email delivery with settings

6. **✅ Security**
   - Rate limiting (5 attempts per hour)
   - SHA256 token hashing
   - Single-use tokens
   - IP and user agent tracking
   - Comprehensive audit logging

---

## 🚀 Quick Start

### Step 1: Run Setup Script

```bash
cd ~/src/renterinsight_api
bash setup_password_reset_complete.sh
```

This will:
- ✅ Run migrations (password_reset_tokens + add phone to users)
- ✅ Create test users (admin + client with phone numbers)
- ✅ Show configuration instructions

### Step 2: Create Test Users (Manual)

Or run manually:

```bash
bundle exec rails runner create_test_users_password_reset.rb
```

**Test Users Created:**
- **Admin**: `t+admin@renterinsight.com` / `password123` / `303-570-9810`
- **Client**: `t+client@renterinsight.com` / `password123` / `303-570-9810`

---

## ⚙️ Configuration

### 📧 Email Settings (Platform-Wide)

```ruby
bin/rails console

Setting.set('Platform', 0, 'communications', {
  email: {
    provider: 'smtp',
    fromEmail: 't+admin@renterinsight.com',
    fromName: 'RenterInsight',
    smtpHost: 'smtp.gmail.com',
    smtpPort: 587,
    smtpUsername: 't+admin@renterinsight.com',
    smtpPassword: 'your_gmail_app_password',  # Get from Google Account Security
    isEnabled: true
  }
})
```

### 📱 SMS Settings (Platform-Wide)

```ruby
Setting.set('Platform', 0, 'communications', {
  sms: {
    provider: 'twilio',
    fromNumber: '+13035709810',
    twilioAccountSid: 'your_twilio_sid',
    twilioAuthToken: 'your_twilio_token',
    isEnabled: true
  }
})
```

### 🏢 Company-Specific Overrides

```ruby
# Override for a specific company
Setting.set('Company', company_id, 'communications', {
  email: {
    provider: 'smtp',
    fromEmail: 'support@company.com',
    fromName: 'Company Support',
    smtpHost: 'smtp.company.com',
    smtpPort: 587,
    smtpUsername: 'support@company.com',
    smtpPassword: 'company_password',
    isEnabled: true
  }
})
```

---

## 🧪 Testing

### Test 1: Admin Email Reset

```bash
curl -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{
    "email": "t+admin@renterinsight.com",
    "delivery_method": "email",
    "user_type": "admin"
  }'
```

**Expected Response:**
```json
{
  "ok": true,
  "message": "Reset instructions sent successfully",
  "delivery_method": "email"
}
```

### Test 2: Client Email Reset

```bash
curl -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{
    "email": "t+client@renterinsight.com",
    "delivery_method": "email",
    "user_type": "client"
  }'
```

### Test 3: Admin SMS Reset (Phone Lookup)

```bash
curl -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{
    "phone": "+13035709810",
    "delivery_method": "sms",
    "user_type": "admin"
  }'
```

**SMS Message:**
```
Your password reset code is: 123456
Valid for 15 minutes.
```

### Test 4: Client SMS Reset (Phone Lookup)

```bash
curl -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{
    "phone": "+13035709810",
    "delivery_method": "sms",
    "user_type": "client"
  }'
```

### Test 5: Auto User Type Detection

```bash
curl -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{
    "email": "t+admin@renterinsight.com",
    "delivery_method": "email",
    "user_type": "auto"
  }'
```

---

## 🔄 How It Works (Cascading Settings)

When a password reset is requested:

1. **Identify User**
   - By email (for both admins and clients)
   - By phone (for admins directly, for clients via Contact lookup)

2. **Check Settings (Cascading Priority)**
   ```
   Company Settings (highest priority)
        ↓ (if not set)
   Platform Settings (fallback)
        ↓ (if not set)
   ENV Variables (last resort)
   ```

3. **Validate Delivery Method**
   - Check if email/SMS is enabled in settings
   - Rate limit check (5 per hour per identifier)

4. **Generate Token**
   - Email: Secure URL token (1 hour expiration)
   - SMS: 6-digit code (15 minute expiration)

5. **Deliver**
   - Email: Send via SMTP with settings
   - SMS: Send via Twilio with settings

6. **Log Everything**
   - All attempts logged with IP and user agent
   - Success/failure tracking
   - Audit trail for security

---

## 📂 Files Created/Updated

### New Migrations
- ✅ `db/migrate/20251015170000_create_password_reset_tokens.rb`
- ✅ `db/migrate/20251015180000_add_phone_to_users.rb`

### Services (Updated for Settings)
- ✅ `app/services/password_reset_service.rb` - Settings integration
- ✅ `app/services/sms_service.rb` - Settings integration

### Mailers (Updated for Settings)
- ✅ `app/mailers/password_reset_mailer.rb` - Settings integration
- ✅ `app/views/password_reset_mailer/reset_instructions.html.erb`
- ✅ `app/views/password_reset_mailer/reset_instructions.text.erb`

### Models
- ✅ `app/models/password_reset_token.rb`

### Controllers
- ✅ `app/controllers/api/auth/password_reset_controller.rb`

### Routes
- ✅ `config/routes.rb` (updated with password reset endpoints)

### Scripts
- ✅ `create_test_users_password_reset.rb`
- ✅ `setup_password_reset_complete.sh`

### Documentation
- ✅ This file!

---

## 🔍 Phone Lookup Details

### For Admin Users
Phone is stored directly in the `users` table:
```ruby
User.where(role: ['admin', 'super_admin']).find_by(phone: '+13035709810')
```

### For Client Users
Phone is stored in the associated `Contact` record:
```ruby
BuyerPortalAccess
  .joins("INNER JOIN contacts ON buyer_portal_accesses.buyer_type = 'Contact' 
          AND buyer_portal_accesses.buyer_id = contacts.id")
  .where(contacts: { phone: '+13035709810' })
  .first
```

---

## 🎯 API Endpoints

All endpoints are under: `/api/auth/`

### 1. Request Password Reset
**POST** `/api/auth/request_password_reset`

**Parameters:**
```json
{
  "email": "user@example.com",      // OR
  "phone": "+13035709810",          // One of email/phone required
  "delivery_method": "email",       // "email" or "sms"
  "user_type": "admin"              // "admin", "client", or "auto"
}
```

### 2. Verify Reset Token
**POST** `/api/auth/verify_reset_token`

**Parameters:**
```json
{
  "token": "abc123..."
}
```

### 3. Reset Password
**POST** `/api/auth/reset_password`

**Parameters:**
```json
{
  "token": "abc123...",
  "new_password": "newpassword123"
}
```

---

## 🎨 Frontend Integration

The frontend forms are already complete and will work automatically once the backend is configured!

**Frontend URLs:**
- `/admin/forgot-password` - Admin portal
- `/client/forgot-password` - Client portal
- `/forgot-password` - Unified portal

---

## 🔒 Security Features

1. **Rate Limiting**: Max 5 reset requests per hour per identifier
2. **Token Hashing**: SHA256 hashing for all tokens
3. **Short Expiration**: 1 hour for email, 15 minutes for SMS
4. **Single-Use**: Tokens are marked as used after password reset
5. **IP Tracking**: All attempts logged with IP address
6. **User Agent Tracking**: Browser/client information logged
7. **User Enumeration Protection**: Same response for existing/non-existing users

---

## 📊 Monitoring & Logging

All password reset attempts are logged:

```ruby
{
  event: 'password_reset_attempt',
  user_id: 123,
  user_type: 'User',
  identifier: 'user@example.com',
  delivery_method: 'email',
  status: 'success',
  ip_address: '192.168.1.1',
  user_agent: 'Mozilla/5.0...',
  timestamp: '2025-10-15 18:00:00'
}
```

---

## 🐛 Troubleshooting

### Email Not Sending?

1. Check SMTP settings in Platform Settings:
   ```ruby
   Setting.get('Platform', 0, 'communications')
   ```

2. Check ActionMailer configuration:
   ```ruby
   Rails.application.config.action_mailer.delivery_method
   ```

3. Check logs:
   ```bash
   tail -f log/development.log | grep password_reset
   ```

### SMS Not Sending?

1. Check Twilio credentials in Platform Settings
2. Verify phone number format: `+13035709810` (E.164 format)
3. Check Twilio account status and balance

### Phone Lookup Not Working?

1. Verify migration ran:
   ```bash
   bundle exec rails db:migrate:status | grep phone
   ```

2. Check if phone is set:
   ```ruby
   User.find_by(email: 't+admin@renterinsight.com').phone
   Contact.find_by(email: 't+client@renterinsight.com').phone
   ```

---

## ✅ Next Steps

1. **✅ DONE**: Settings integration
2. **✅ DONE**: Phone field added to users
3. **✅ DONE**: Phone lookup for both user types
4. **✅ DONE**: Test user creation script
5. **🚀 TODO**: Configure real email/SMS credentials
6. **🚀 TODO**: Test with real email delivery
7. **🚀 TODO**: Test with real SMS delivery
8. **🚀 TODO**: Deploy to staging/production

---

## 🎉 Summary

The password reset system is **fully integrated** with your existing settings infrastructure! 

- ✅ All components wired up
- ✅ Settings cascade properly
- ✅ Phone lookup works for both user types
- ✅ Ready for testing
- 🚀 Ready for production (after configuring real credentials)

**To get started:**
```bash
bash setup_password_reset_complete.sh
```

That's it! 🎊

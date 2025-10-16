# 🎯 Password Reset - Quick Reference

## 🚀 ONE-LINE SETUP
```bash
cd ~/src/renterinsight_api && bash setup_password_reset_complete.sh
```

## 👥 Test Users
| Type   | Email                       | Phone          | Password    |
|--------|----------------------------|----------------|-------------|
| Admin  | t+admin@renterinsight.com  | 303-570-9810   | password123 |
| Client | t+client@renterinsight.com | 303-570-9810   | password123 |

## 🧪 Quick Tests

### 1. Admin Email Reset
```bash
curl -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{"email":"t+admin@renterinsight.com","delivery_method":"email","user_type":"admin"}'
```

### 2. Client Email Reset
```bash
curl -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{"email":"t+client@renterinsight.com","delivery_method":"email","user_type":"client"}'
```

### 3. Admin SMS Reset (Phone)
```bash
curl -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{"phone":"+13035709810","delivery_method":"sms","user_type":"admin"}'
```

### 4. Client SMS Reset (Phone)
```bash
curl -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{"phone":"+13035709810","delivery_method":"sms","user_type":"client"}'
```

### 5. Auto-Detect User Type
```bash
curl -X POST http://localhost:3001/api/auth/request_password_reset \
  -H "Content-Type: application/json" \
  -d '{"email":"t+admin@renterinsight.com","delivery_method":"email","user_type":"auto"}'
```

## ⚙️ Quick Config (Rails Console)

### Email (Gmail)
```ruby
Setting.set('Platform', 0, 'communications', {
  email: {
    provider: 'smtp',
    fromEmail: 't+admin@renterinsight.com',
    fromName: 'RenterInsight',
    smtpHost: 'smtp.gmail.com',
    smtpPort: 587,
    smtpUsername: 't+admin@renterinsight.com',
    smtpPassword: 'your_app_password',
    isEnabled: true
  }
})
```

### SMS (Twilio)
```ruby
Setting.set('Platform', 0, 'communications', {
  sms: {
    provider: 'twilio',
    fromNumber: '+13035709810',
    twilioAccountSid: 'AC...',
    twilioAuthToken: 'token...',
    isEnabled: true
  }
})
```

## 📊 Check Settings
```ruby
# View current settings
Setting.get('Platform', 0, 'communications')

# Test email config
PasswordResetMailer.reset_instructions(
  email: 't+admin@renterinsight.com',
  token: 'test123',
  reset_url: 'http://localhost:3000/reset?token=test123',
  user_name: 'Tom'
).deliver_now
```

## 🔍 Debug Commands

### Check Users
```ruby
User.find_by(email: 't+admin@renterinsight.com')
BuyerPortalAccess.find_by(email: 't+client@renterinsight.com')
```

### Check Phone Lookups
```ruby
User.find_by(phone: '303-570-9810')
Contact.find_by(phone: '303-570-9810')
```

### Check Recent Tokens
```ruby
PasswordResetToken.order(created_at: :desc).limit(5)
```

## 📋 API Endpoints
- `POST /api/auth/request_password_reset` - Request reset
- `POST /api/auth/verify_reset_token` - Verify token
- `POST /api/auth/reset_password` - Complete reset

## 🎨 Frontend URLs
- `/admin/forgot-password` - Admin portal
- `/client/forgot-password` - Client portal  
- `/forgot-password` - Unified portal

## 🔒 Security
- Rate limit: 5 attempts/hour per identifier
- Email tokens: 1 hour expiration
- SMS codes: 15 minute expiration
- Single-use tokens
- IP tracking & audit logs

## 📚 Full Documentation
See: `PASSWORD_RESET_SETTINGS_INTEGRATION.md`

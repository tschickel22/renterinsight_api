# 🔍 Why You Didn't Receive Emails/SMS

## What Happened

Your password reset requests **succeeded** but you didn't receive emails or SMS because:

### 📧 Email Issue
**ActionMailer is in TEST mode** (default for development)
- Emails are "sent" but **captured in memory**, not actually delivered
- This is Rails' default behavior to prevent accidental email sending during development
- The log shows "success" because the system processed it correctly

**Current Config:**
```ruby
config.action_mailer.delivery_method = :test  # Emails go to memory
config.action_mailer.raise_delivery_errors = false  # Errors hidden
```

### 📱 SMS Issue  
**Phone lookup failed** for the client user
- Client phone is stored in the `contacts` table, not `buyer_portal_accesses`
- The phone format was wrong: `303-570-9810` instead of `+13035709810`
- Also, Twilio credentials aren't configured yet

---

## 🔧 How to Fix

### Quick Fix (Run This)
```bash
cd ~/src/renterinsight_api
bash debug_password_reset.sh
```

This will:
1. ✅ Fix phone numbers to correct format (+13035709810)
2. ✅ Test email configuration
3. ✅ Show you where emails are captured
4. ✅ Run test requests again

### Manual Fixes

#### Fix 1: Phone Numbers
```bash
bundle exec rails runner fix_test_users.rb
```

This ensures:
- Admin user has phone: `303-570-9810` in `users.phone`
- Client contact has phone: `+13035709810` in `contacts.phone` (E.164 format)

#### Fix 2: View Captured Emails
```bash
bundle exec rails console
```

Then:
```ruby
# See all captured emails
ActionMailer::Base.deliveries.count

# View last email
mail = ActionMailer::Base.deliveries.last
puts "From: #{mail.from}"
puts "To: #{mail.to}"
puts "Subject: #{mail.subject}"
puts mail.body
```

---

## 📧 To Send REAL Emails

### Option 1: Use Gmail (Easiest for Testing)

1. **Get Gmail App Password**
   - Go to Google Account → Security → 2-Step Verification → App passwords
   - Generate a new app password for "Mail"
   - Copy the 16-character password

2. **Add to `.env` file:**
   ```env
   SMTP_ADDRESS=smtp.gmail.com
   SMTP_PORT=587
   SMTP_USERNAME=your_email@gmail.com
   SMTP_PASSWORD=your_16_char_app_password
   ```

3. **Update `config/environments/development.rb`:**
   ```ruby
   config.action_mailer.delivery_method = :smtp
   config.action_mailer.raise_delivery_errors = true
   config.action_mailer.perform_deliveries = true
   
   config.action_mailer.smtp_settings = {
     address: ENV['SMTP_ADDRESS'],
     port: ENV['SMTP_PORT'],
     user_name: ENV['SMTP_USERNAME'],
     password: ENV['SMTP_PASSWORD'],
     authentication: 'plain',
     enable_starttls_auto: true
   }
   ```

4. **Restart Rails server**

5. **Test again:**
   ```bash
   curl -X POST http://localhost:3001/api/auth/request_password_reset \
     -H "Content-Type: application/json" \
     -d '{"email":"t+admin@renterinsight.com","delivery_method":"email","user_type":"admin"}'
   ```

### Option 2: Use Platform Settings (Production Way)

```bash
bundle exec rails console
```

```ruby
Setting.set('Platform', 0, 'communications', {
  email: {
    provider: 'smtp',
    fromEmail: 'your_email@gmail.com',
    fromName: 'RenterInsight',
    smtpHost: 'smtp.gmail.com',
    smtpPort: 587,
    smtpUsername: 'your_email@gmail.com',
    smtpPassword: 'your_app_password',
    isEnabled: true
  }
})
```

Then restart server and test.

---

## 📱 To Send REAL SMS

### Setup Twilio

1. **Sign up for Twilio** (free trial works)
   - Get Account SID
   - Get Auth Token
   - Get a phone number

2. **Configure via Settings:**
   ```bash
   bundle exec rails console
   ```
   
   ```ruby
   Setting.set('Platform', 0, 'communications', {
     sms: {
       provider: 'twilio',
       fromNumber: '+15551234567',  # Your Twilio number
       twilioAccountSid: 'AC...',   # Your Account SID
       twilioAuthToken: 'token...',  # Your Auth Token
       isEnabled: true
     }
   })
   ```

3. **Test SMS:**
   ```bash
   curl -X POST http://localhost:3001/api/auth/request_password_reset \
     -H "Content-Type: application/json" \
     -d '{"phone":"+13035709810","delivery_method":"sms","user_type":"client"}'
   ```

---

## 🧪 Testing Without Real Delivery

If you just want to test the **logic** without sending real emails/SMS:

### Check Email Content
```bash
bundle exec rails console
```

```ruby
# Clear previous emails
ActionMailer::Base.deliveries.clear

# Manually trigger email
PasswordResetMailer.reset_instructions(
  email: 't+admin@renterinsight.com',
  token: 'test123',
  reset_url: 'http://localhost:3000/reset?token=test123',
  user_name: 'Tom',
  email_settings: {}
).deliver_now

# View the captured email
mail = ActionMailer::Base.deliveries.last
puts mail.subject
puts mail.body
```

### Check SMS Would Be Sent
Look at your Rails logs after making a request - it will log the SMS message:
```
SMS send failed: [ERROR MESSAGE]
```

Or if SMS service is mocked, you'll see the message body in logs.

---

## 📊 What Your Logs Show

### Email Request (Admin)
```
"event":"password_reset_attempt"
"user_id":11
"status":"success"  ← Email was "sent" (captured in test mode)
```

### SMS Request (Client)  
```
"status":"user_not_found"  ← Phone lookup failed
```

This is because:
1. Client phone wasn't in E.164 format
2. Client phone is in `contacts` table, requires special join query

---

## ✅ Quick Solution Summary

Run this **one command**:
```bash
cd ~/src/renterinsight_api && bash debug_password_reset.sh
```

This will:
1. Fix phone numbers
2. Test email configuration  
3. Show you where emails are captured
4. Run test requests

**Then** decide if you want to:
- ✅ **Just test the logic**: Use TEST mode (current) and check `ActionMailer::Base.deliveries`
- 📧 **Send real emails**: Configure Gmail SMTP (see above)
- 📱 **Send real SMS**: Configure Twilio (see above)

---

## 💡 Pro Tips

1. **For development**: TEST mode is perfect - no real emails sent accidentally
2. **For testing real delivery**: Use Gmail with app password (easiest)
3. **For production**: Use Platform Settings (more flexible)
4. **Check logs**: `tail -f log/development.log | grep password_reset`
5. **Phone format**: Always use E.164 (+13035709810) for SMS

---

## 🎯 Next Steps

1. **Run:** `bash debug_password_reset.sh`
2. **Check:** `ActionMailer::Base.deliveries` in console
3. **Decide:** Do you need real delivery now, or test logic first?
4. **Configure:** If real delivery needed, set up Gmail SMTP
5. **Test:** Run curl commands again

**The system is working!** It's just in TEST mode by default. 🎉

# PROPER FIX - Following Your Architecture Pattern

## ✅ What I Fixed

I've updated the code to follow **your existing pattern** from `password_reset_service.rb`:

### 1. Updated `communication_service.rb` ✅
**Added company extraction and passing to providers**

```ruby
def send_via_provider(provider:, channel:, communication:, options:)
  # Extract company from communicable for settings lookup
  company = extract_company_from_communicable(communication.communicable)
  
  provider_class = get_provider_class(provider, channel)
  provider_instance = provider_class.new(company: company)  # ← Now passes company!
  # ...
end

def extract_company_from_communicable(communicable)
  case communicable.class.name
  when 'Quote'
    communicable.account&.company || communicable.contact&.company
  when 'Account', 'Contact'
    communicable.company
  # ... handles other types
  end
end
```

### 2. Updated `smtp_provider.rb` ✅
**Now uses CommunicationSettingsService with Company → Platform → ENV hierarchy**

```ruby
def initialize(company: nil)
  @company = company
  
  # Get settings from Company → Platform → ENV hierarchy
  settings_service = company ? 
    CommunicationSettingsService.for_company(company) : 
    CommunicationSettingsService.platform
  
  email_config = settings_service.email_config
  
  @config = {
    address: email_config[:smtp_host],
    port: email_config[:smtp_port],
    domain: email_config[:smtp_domain],
    user_name: email_config[:smtp_username],
    password: email_config[:smtp_password],  # ← Properly decrypted!
    authentication: email_config[:smtp_authentication] || 'plain',
    enable_starttls_auto: true
  }
end
```

### 3. Created `set_smtp_password.rb` ✅
**Encryption script following password_reset_service.rb pattern**

Uses the **exact same encryption** as your password reset:
```ruby
secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
crypt = ActiveSupport::MessageEncryptor.new(key)
encrypted = "encrypted:" + crypt.encrypt_and_sign(password)
```

## 📊 Architecture Pattern (Same as Password Reset)

```
┌─────────────────────────────────────────────────┐
│  1. CommunicationService                        │
│     - Extracts company from communicable        │
│     - Passes company to provider                │
└────────────────────┬────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────┐
│  2. SmtpProvider.new(company: company)          │
│     - Receives company parameter                │
│     - Uses CommunicationSettingsService         │
└────────────────────┬────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────┐
│  3. CommunicationSettingsService                │
│                                                  │
│     Priority order:                             │
│     1st: Company settings (if company present)  │
│     2nd: Platform settings                      │
│     3rd: ENV variables (fallback)               │
│                                                  │
│     - Loads from Settings table                 │
│     - Decrypts "encrypted:..." values           │
│     - Returns config hash                       │
└────────────────────┬────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────┐
│  4. Settings Table (Database)                   │
│                                                  │
│     Platform settings:                          │
│       scope_type: 'Platform'                    │
│       scope_id: 0                               │
│       key: 'communications'                     │
│       value: {                                  │
│         "email": {                              │
│           "smtpPassword": "encrypted:ABC..."    │
│         }                                       │
│       }                                         │
│                                                  │
│     Company settings (override):                │
│       scope_type: 'Company'                     │
│       scope_id: <company_id>                    │
│       key: 'communications'                     │
│       value: { ... company-specific ... }       │
└─────────────────────────────────────────────────┘
```

## 🔐 Encryption/Decryption Flow

**Same as password_reset_service.rb:**

### Storing Password:
```ruby
1. User enters: "my_gmail_app_password"
2. Encrypt:
   secret_key = ENV['SETTINGS_ENCRYPTION_KEY'] || Rails.application.secret_key_base
   key = ActiveSupport::KeyGenerator.new(secret_key).generate_key('', 32)
   crypt = ActiveSupport::MessageEncryptor.new(key)
   encrypted = crypt.encrypt_and_sign("my_gmail_app_password")
3. Store as: "encrypted:ABC123XYZ..."
```

### Retrieving Password:
```ruby
1. Load from DB: "encrypted:ABC123XYZ..."
2. Decrypt (in CommunicationSettingsService.decrypt_value):
   - Strips "encrypted:" prefix
   - Uses same key as above
   - Returns: "my_gmail_app_password"
3. Provider receives decrypted password
```

## 🚀 How To Use

### Step 1: Set Encrypted Password
```bash
cd ~/src/renterinsight_api
bundle exec rails runner set_smtp_password.rb
# Enter your Gmail App Password when prompted
```

### Step 2: Restart Rails
```bash
pkill -f "rails s"
rails s
```

### Step 3: Test Email Sending
```bash
bundle exec rails console
```

```ruby
# Test with Quote #22
quote = Quote.find(22)
service = QuoteSendingService.new(quote)
result = service.send(
  delivery_methods: ['email'], 
  to_email: 'tom@renterinsight.com'
)

# Check result
if result[:sent].any?
  puts "✅ SUCCESS!"
  puts result.inspect
else
  puts "❌ FAILED"
  puts "Errors: #{result[:errors]}"
end
```

## 🎯 Expected Results

### Before Fix:
```ruby
# SmtpProvider tried to read from Rails.application.config
{:smtp_password=>nil}  # ❌ nil!

# Email sending failed
{:sent=>[], :failed=>[...], :errors=>["undefined method `[]' for nil"]}
```

### After Fix:
```ruby
# SmtpProvider uses CommunicationSettingsService
{:smtp_password=>"your_actual_decrypted_password"}  # ✅

# Email sends successfully
{:sent=>[{:channel=>"email", :to=>"tom@renterinsight.com"}], :failed=>[], :errors=>[]}
```

## 📝 Files Modified

1. ✅ `app/services/communication_service.rb`
   - Added `extract_company_from_communicable()` method
   - Updated `send_via_provider()` to pass company parameter

2. ✅ `app/services/providers/email/smtp_provider.rb`
   - Updated `initialize()` to accept `company:` parameter
   - Now uses `CommunicationSettingsService` instead of ENV/Rails.application.config

3. ✅ `set_smtp_password.rb` (NEW)
   - Script to encrypt and store SMTP password
   - Follows same pattern as password_reset_service.rb
   - Tests encryption/decryption before saving

## ⚙️ Settings Hierarchy

The system now properly supports:

### Platform Settings (Default)
```ruby
Setting.set('Platform', 0, 'communications', {
  'email' => {
    'provider' => 'smtp',
    'smtpHost' => 'smtp.gmail.com',
    'smtpPassword' => 'encrypted:...',
    # ...
  }
})
```

### Company Settings (Override Platform)
```ruby
Setting.set('Company', company.id, 'communications', {
  'email' => {
    'provider' => 'smtp',
    'smtpHost' => 'smtp.corporate.com',  # Company's own SMTP
    'smtpPassword' => 'encrypted:...',   # Company's password
    # ...
  }
})
```

### ENV Variables (Ultimate Fallback)
```bash
SMTP_ADDRESS=smtp.gmail.com
SMTP_USERNAME=user@example.com
SMTP_PASSWORD=plain_password
```

## ✨ Benefits

1. **Follows Your Existing Pattern** - Same as password_reset_service.rb
2. **Company-Specific Settings** - Each company can have their own SMTP
3. **Secure Encryption** - Uses same encryption as password reset
4. **Graceful Fallback** - Company → Platform → ENV
5. **No Breaking Changes** - Works with existing CommunicationSettingsService

## 🔍 Verification

To verify it's working:

```ruby
# Check settings service
settings = CommunicationSettingsService.platform
config = settings.email_config
puts "Password: #{config[:smtp_password] ? 'SET ✅' : 'NIL ❌'}"

# Check with company
company = Company.first
settings = CommunicationSettingsService.for_company(company)
config = settings.email_config
puts "Company password: #{config[:smtp_password] ? 'SET ✅' : 'NIL ❌'}"
```

## 🎉 Summary

This fix **properly follows your architecture** by:
- ✅ Using the same encryption pattern as password_reset_service.rb
- ✅ Supporting Company → Platform → ENV hierarchy
- ✅ Passing company context through the service chain
- ✅ Using your existing CommunicationSettingsService
- ✅ No hardcoded credentials or hacky workarounds

The pattern is now **consistent across your entire codebase**! 🚀

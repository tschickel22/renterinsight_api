# Unified Communication System - Phase 1

A comprehensive, production-ready communication infrastructure for Platform DMS that unifies email, SMS, and portal messaging with built-in compliance, tracking, and provider abstraction.

## 🎯 Overview

This Phase 1 implementation provides:

- **4 Models**: Communication, CommunicationThread, CommunicationPreference, CommunicationEvent
- **6 Services**: Main orchestrator + preference service + 4 provider implementations
- **4 Migrations**: Database schema for all tables
- **100% Backward Compatibility**: Wrapper for existing QuoteEmailService
- **Full Test Coverage**: Comprehensive RSpec tests for all components

## 📋 Features

### Core Capabilities
- ✅ Polymorphic associations (Lead, Account, Quote, etc.)
- ✅ Multi-channel support (Email, SMS, Portal Messages)
- ✅ Direction tracking (Outbound/Inbound)
- ✅ Conversation threading
- ✅ Portal visibility controls
- ✅ Comprehensive event tracking (Opens, Clicks, Deliveries, Bounces)

### Compliance & Preferences
- ✅ Opt-in/opt-out management with compliance tracking
- ✅ One-click unsubscribe with secure tokens
- ✅ Category-based preferences (Marketing, Transactional, Quotes, etc.)
- ✅ Automatic hard bounce and spam complaint handling
- ✅ Full audit trail with IP addresses and user agents

### Provider Abstraction
- ✅ SMTP Provider (built-in ActionMailer)
- ✅ Gmail Relay Provider
- ✅ AWS SES Provider (with webhook support)
- ✅ Twilio SMS Provider
- ✅ Easy provider switching at runtime
- ✅ Consistent interface across all providers

## 🚀 Installation

### Step 1: Copy Files

Copy all files from this package to your Rails application:

```bash
# Models
cp app/models/*.rb YOUR_APP/app/models/
cp app/models/concerns/communicable.rb YOUR_APP/app/models/concerns/

# Services
cp app/services/*.rb YOUR_APP/app/services/
cp -r app/services/providers YOUR_APP/app/services/

# Migrations
cp db/migrate/*.rb YOUR_APP/db/migrate/
# Rename migrations with current timestamp:
# rails g migration --skip and copy the content

# Tests
cp spec/models/*.rb YOUR_APP/spec/models/
cp spec/services/*.rb YOUR_APP/spec/services/
```

### Step 2: Install Dependencies

Add to your `Gemfile`:

```ruby
# For AWS SES (optional)
gem 'aws-sdk-ses', '~> 1.0'

# For Twilio SMS (if not already present)
gem 'twilio-ruby', '~> 5.0'
```

Run:
```bash
bundle install
```

### Step 3: Run Migrations

```bash
rails db:migrate
```

This creates 4 tables:
- `communications` - Main communication records
- `communication_threads` - Conversation threading
- `communication_preferences` - Opt-in/out with compliance
- `communication_events` - Event tracking

### Step 4: Update Existing Models

Add the `Communicable` concern to your existing models:

```ruby
# app/models/lead.rb
class Lead < ApplicationRecord
  include Communicable
  
  def primary_email
    email
  end
  
  def primary_phone
    phone
  end
end

# app/models/account.rb
class Account < ApplicationRecord
  include Communicable
  
  def primary_email
    primary_contact&.email || contacts.first&.email
  end
  
  def primary_phone
    primary_contact&.phone || contacts.first&.phone
  end
end

# app/models/quote.rb
class Quote < ApplicationRecord
  include Communicable
  
  def primary_email
    lead&.email || account&.primary_email
  end
  
  def primary_phone
    lead&.phone || account&.primary_phone
  end
end
```

### Step 5: Configure Environment Variables

Add to your `.env` or environment configuration:

```bash
# Email Configuration
DEFAULT_EMAIL_PROVIDER=smtp  # Options: smtp, gmail_relay, aws_ses
DEFAULT_FROM_EMAIL=noreply@platformdms.com
COMPANY_NAME=Platform DMS
APP_BASE_URL=https://app.platformdms.com

# SMTP Configuration (if using SMTP provider)
SMTP_ADDRESS=smtp.example.com
SMTP_PORT=587
SMTP_DOMAIN=platformdms.com
SMTP_USERNAME=your_username
SMTP_PASSWORD=your_password

# Gmail Relay Configuration (if using Gmail Relay)
GMAIL_RELAY_DOMAIN=platformdms.com
GMAIL_RELAY_USERNAME=relay@platformdms.com
GMAIL_RELAY_PASSWORD=your_app_password

# AWS SES Configuration (if using AWS SES)
AWS_SES_REGION=us-east-1
AWS_ACCESS_KEY_ID=your_access_key
AWS_SECRET_ACCESS_KEY=your_secret_key
AWS_SES_CONFIGURATION_SET=platform-dms-emails

# Twilio Configuration (for SMS)
TWILIO_ACCOUNT_SID=your_account_sid
TWILIO_AUTH_TOKEN=your_auth_token
TWILIO_PHONE_NUMBER=+11234567890
TWILIO_MESSAGING_SERVICE_SID=your_messaging_service_sid  # Optional
```

### Step 6: Wrap Existing QuoteEmailService (Optional)

If you have an existing `QuoteEmailService`, wrap it for backward compatibility:

```ruby
# app/services/quote_email_service.rb
class QuoteEmailService
  def initialize(quote)
    @wrapper = QuoteEmailServiceWrapper.new(quote)
  end
  
  def send_email(to:, **options)
    @wrapper.send_email(to: to, **options)
  end
  
  # Delegate other methods
  delegate :deliver, :resend, :send_to_multiple, :can_send_to?, 
           :send_history, :last_sent, :sent?, :delivered?, :opened?,
           to: :@wrapper
end
```

## 📖 Usage Examples

### Basic Email Sending

```ruby
# Send a simple email
lead = Lead.find(1)
lead.send_email(
  to: 'customer@example.com',
  subject: 'Welcome!',
  body: 'Thanks for signing up!'
)

# Or use the service directly
CommunicationService.send_email(
  communicable: lead,
  to: 'customer@example.com',
  subject: 'Welcome!',
  body: 'Thanks for signing up!',
  category: 'marketing'
)
```

### Send Quote Email (Backward Compatible)

```ruby
quote = Quote.find(1)

# Old way (still works)
QuoteEmailService.new(quote).send_email(
  to: 'customer@example.com'
)

# New way (recommended)
CommunicationService.send_quote_email(
  quote: quote,
  to: 'customer@example.com',
  subject: "Quote ##{quote.id}",
  body: quote_email_body
)
```

### Send SMS

```ruby
lead = Lead.find(1)
lead.send_sms(
  to: '+11234567890',
  body: 'Your quote is ready!'
)

# Or use the service
CommunicationService.send_sms(
  communicable: lead,
  to: '+11234567890',
  body: 'Your quote is ready!',
  category: 'notifications'
)
```

### Portal Messages

```ruby
lead = Lead.find(1)
lead.send_portal_message(
  to: 'customer@example.com',
  body: 'Your application has been approved!'
)
```

### Provider Switching

```ruby
# Use specific provider
CommunicationService.send_email(
  communicable: lead,
  to: 'customer@example.com',
  subject: 'Test',
  body: 'Testing AWS SES',
  provider: :aws_ses  # Options: :smtp, :gmail_relay, :aws_ses
)
```

### Managing Communication Preferences

```ruby
lead = Lead.find(1)

# Opt out of marketing emails
CommunicationPreferenceService.opt_out(
  recipient: lead,
  channel: 'email',
  category: 'marketing',
  reason: 'Not interested',
  ip_address: request.ip,
  user_agent: request.user_agent
)

# Opt back in
CommunicationPreferenceService.opt_in(
  recipient: lead,
  channel: 'email',
  category: 'marketing',
  ip_address: request.ip
)

# Check if can send
if CommunicationPreferenceService.can_send_to?(
  recipient: lead,
  channel: 'email',
  category: 'marketing'
)
  # Send marketing email
end

# Generate unsubscribe URL
unsubscribe_url = CommunicationPreferenceService.unsubscribe_url(
  recipient: lead,
  channel: 'email',
  category: 'marketing'
)
```

### Unsubscribe Handling

```ruby
# In your UnsubscribeController
def unsubscribe
  preference = CommunicationPreferenceService.unsubscribe_by_token(
    token: params[:token],
    ip_address: request.ip,
    user_agent: request.user_agent
  )
  
  flash[:notice] = "You have been unsubscribed"
  redirect_to root_path
rescue CommunicationPreferenceService::Error => e
  flash[:error] = "Invalid unsubscribe link"
  redirect_to root_path
end
```

### Tracking Events

```ruby
communication = Communication.find(1)

# Track open
communication.track_event('opened', {
  ip_address: request.ip,
  user_agent: request.user_agent
})

# Track click
communication.track_event('clicked', {
  url: 'https://example.com/quote',
  ip_address: request.ip
})

# Check tracking
if communication.opened?
  puts "Email was opened!"
end

if communication.clicked?
  puts "Link was clicked!"
end
```

### Querying Communications

```ruby
lead = Lead.find(1)

# Get all communications
lead.communications

# Get recent emails
lead.email_communications.recent.limit(10)

# Get sent communications
lead.outbound_communications.sent

# Get communication stats
stats = lead.communication_stats
# => {
#   total_sent: 45,
#   total_received: 12,
#   emails_sent: 40,
#   sms_sent: 5,
#   delivered_count: 42,
#   failed_count: 3,
#   last_communication_at: 2025-01-15 10:30:00
# }
```

### Thread Management

```ruby
# Get all communications in a thread
thread = CommunicationThread.find(1)
thread.communications

# Get thread stats
stats = thread.stats
# => {
#   total_messages: 15,
#   outbound_count: 10,
#   inbound_count: 5,
#   opened_count: 8,
#   clicked_count: 3
# }

# Archive thread
thread.archive!

# Close thread
thread.close!
```

### Compliance Reporting

```ruby
lead = Lead.find(1)

# Generate compliance report
report = CommunicationPreferenceService.compliance_report(recipient: lead)

# Report includes:
# - All preferences with opt-in/out status
# - Timestamps for all preference changes
# - IP addresses and user agents
# - Full audit trail
# - Total communications sent
```

## 🧪 Testing

Run the test suite:

```bash
# Run all tests
rspec spec/models/communication_spec.rb
rspec spec/models/communication_preference_spec.rb
rspec spec/services/communication_service_spec.rb
rspec spec/services/communication_preference_service_spec.rb

# Or run all at once
rspec spec/models spec/services
```

## 🔧 Configuration

### Email Provider Configuration

#### SMTP
```ruby
# config/environments/production.rb
config.action_mailer.smtp_settings = {
  address: ENV['SMTP_ADDRESS'],
  port: ENV['SMTP_PORT'],
  domain: ENV['SMTP_DOMAIN'],
  user_name: ENV['SMTP_USERNAME'],
  password: ENV['SMTP_PASSWORD'],
  authentication: 'plain',
  enable_starttls_auto: true
}
```

#### AWS SES
```ruby
# Add to Gemfile
gem 'aws-sdk-ses'

# Environment variables needed:
# AWS_SES_REGION
# AWS_ACCESS_KEY_ID
# AWS_SECRET_ACCESS_KEY
# AWS_SES_CONFIGURATION_SET (optional)
```

#### Gmail Relay
```ruby
# Environment variables needed:
# GMAIL_RELAY_DOMAIN
# GMAIL_RELAY_USERNAME
# GMAIL_RELAY_PASSWORD
```

### SMS Provider Configuration

#### Twilio
```ruby
# Add to Gemfile (if not present)
gem 'twilio-ruby'

# Environment variables needed:
# TWILIO_ACCOUNT_SID
# TWILIO_AUTH_TOKEN
# TWILIO_PHONE_NUMBER
# TWILIO_MESSAGING_SERVICE_SID (optional)
```

## 📊 Database Schema

### Communications Table
- Polymorphic `communicable` (Lead, Account, Quote, etc.)
- `direction`: outbound/inbound
- `channel`: email/sms/portal_message
- `provider`: smtp/gmail_relay/aws_ses/twilio
- `status`: pending/sent/delivered/failed/bounced
- Threading via `communication_thread_id`
- Portal visibility flag
- Metadata JSONB for flexible data
- External provider message IDs

### Communication Threads Table
- Groups related communications
- Status: active/archived/closed
- Last message timestamp
- Metadata JSONB

### Communication Preferences Table
- Polymorphic `recipient`
- Channel and category combinations
- Opt-in/out status with timestamps
- Secure unsubscribe tokens
- Compliance metadata with full audit trail

### Communication Events Table
- Tracks: sent, delivered, opened, clicked, bounced, failed, unsubscribed, spam_report
- IP address and user agent tracking
- Event details JSONB

## 🔐 Security & Compliance

### Opt-Out Compliance
- One-click unsubscribe links
- Secure tokens (32-byte URL-safe)
- IP address and user agent logging
- Full audit trail for compliance
- Automatic hard bounce handling
- Spam complaint processing

### Data Protection
- Polymorphic associations prevent data leaks
- JSONB metadata for flexible, secure storage
- Foreign key constraints
- Proper indexing for performance

## 🎯 Next Steps (Future Phases)

Phase 1 provides the foundation. Future phases will add:

- **Phase 2**: Template system with variables and attachments
- **Phase 3**: Scheduling and queueing with background jobs
- **Phase 4**: Analytics dashboard and reporting
- **Phase 5**: A/B testing and optimization
- **Phase 6**: Frontend components and UI

## 📝 Notes

### Backward Compatibility
- 100% compatible with existing QuoteEmailService
- No changes to existing code required
- Gradual migration supported
- All existing functionality preserved

### Performance
- Indexed for common query patterns
- JSONB for flexible metadata without joins
- Efficient polymorphic queries
- Thread-based conversation grouping

### Extensibility
- Easy to add new channels (WhatsApp, Push, etc.)
- Provider abstraction allows easy switching
- Polymorphic design supports any model
- Metadata fields for custom data

## 🆘 Support

For issues or questions:
1. Check the example files in `/examples`
2. Review the test files for usage patterns
3. See model documentation in comments

## 📄 License

Internal Platform DMS project - proprietary code.

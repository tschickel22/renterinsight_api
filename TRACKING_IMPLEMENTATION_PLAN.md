# 📊 Email & SMS Tracking Implementation Plan

## 🎯 Overview
Implement complete tracking for email opens, email delivery, and SMS delivery using webhooks and tracking pixels.

---

## ✅ Current Status

### Already Complete:
- ✅ Database fields exist: `communications.read_at`, `delivered_at`, `received_at`
- ✅ `CommunicationEvent` model exists for tracking events
- ✅ Frontend UI displays read receipts (just implemented)
- ✅ Email and SMS sending infrastructure working

### Missing:
- ❌ Webhook endpoints to receive tracking events
- ❌ Email tracking pixel implementation
- ❌ Twilio SMS delivery webhooks
- ❌ Email provider webhook handlers (Gmail SMTP, SendGrid, etc.)

---

## 📋 Implementation Checklist

### Part 1: Webhook Infrastructure (Backend)
- [ ] Create webhooks controller (`app/controllers/api/webhooks_controller.rb`)
- [ ] Add webhook routes (no authentication for provider webhooks)
- [ ] Implement Twilio SMS status webhook handler
- [ ] Implement email tracking pixel endpoint
- [ ] Add security: verify webhook signatures
- [ ] Update `Communication` model with tracking helper methods

### Part 2: Email Tracking Pixel
- [ ] Generate tracking pixel URL for each email
- [ ] Embed 1x1 transparent GIF in email HTML
- [ ] Create pixel serving endpoint
- [ ] Update `read_at` timestamp when pixel loads
- [ ] Create `CommunicationEvent` record for opens

### Part 3: Twilio SMS Webhooks
- [ ] Configure Twilio account to send delivery status webhooks
- [ ] Create endpoint to receive Twilio status callbacks
- [ ] Update `delivered_at` when SMS is delivered
- [ ] Handle failed/bounced SMS messages
- [ ] Create `CommunicationEvent` records

### Part 4: Settings Integration
- [ ] Add webhook URL to platform settings
- [ ] Display webhook URLs in admin UI for configuration
- [ ] Test with ngrok for local development

---

## 🔧 Technical Implementation

### 1. Webhook Routes (config/routes.rb)

```ruby
# Add BEFORE the authenticated API routes
namespace :webhooks do
  # Email tracking pixel (no auth required)
  get 'email/:communication_id/pixel.gif', to: 'email_tracking#pixel', as: :email_pixel
  
  # Twilio SMS status callbacks (Twilio signature verification)
  post 'twilio/sms/status', to: 'twilio#sms_status'
  
  # SendGrid webhooks (if using SendGrid)
  post 'sendgrid/events', to: 'sendgrid#events'
  
  # Mailgun webhooks (if using Mailgun)
  post 'mailgun/events', to: 'mailgun#events'
end
```

### 2. Webhooks Controller Structure

```
app/controllers/webhooks/
├── email_tracking_controller.rb    # Tracking pixel
├── twilio_controller.rb            # SMS delivery status
├── sendgrid_controller.rb          # Email provider (if used)
└── mailgun_controller.rb           # Email provider (if used)
```

### 3. Email Tracking Pixel Implementation

**Where**: Modify `send_email_via_action_mailer` in `platform/communications_controller.rb`

**Add tracking pixel to email body**:
```ruby
def add_tracking_pixel_to_email(body, communication_id)
  pixel_url = webhooks_email_pixel_url(
    communication_id: communication_id,
    host: ENV['APP_HOST'] || 'localhost:3001'
  )
  
  tracking_pixel = %(<img src="#{pixel_url}" width="1" height="1" style="display:none" />)
  
  # Add pixel before closing </body> tag if HTML
  if body.include?('</body>')
    body.gsub('</body>', "#{tracking_pixel}</body>")
  else
    # Plain text - append pixel wrapped in HTML
    "#{body}\n\n<html><body>#{tracking_pixel}</body></html>"
  end
end
```

### 4. Twilio Webhook Configuration

**Twilio Dashboard Settings**:
- Go to Phone Numbers → Active Numbers → Select your number
- **Messaging Configuration**:
  - Status Callback URL: `https://yourdomain.com/webhooks/twilio/sms/status`
  - POST method
  - Select: Queued, Sent, Delivered, Failed

**Status mapping**:
- `queued` → Don't update (normal)
- `sent` → Update `sent_at` 
- `delivered` → Update `delivered_at` and status = 'delivered'
- `failed` / `undelivered` → Update status = 'failed'

---

## 📝 Implementation Files

### File 1: webhooks/email_tracking_controller.rb

```ruby
# frozen_string_literal: true

module Webhooks
  class EmailTrackingController < ApplicationController
    skip_before_action :verify_authenticity_token
    skip_before_action :authenticate_user!
    
    # GET /webhooks/email/:communication_id/pixel.gif
    def pixel
      communication = Communication.find_by(id: params[:communication_id])
      
      if communication && communication.read_at.nil?
        # Mark as read
        communication.update!(read_at: Time.current)
        
        # Track event
        CommunicationEvent.track_open(
          communication,
          ip_address: request.remote_ip,
          user_agent: request.user_agent
        )
        
        Rails.logger.info "[EmailTracking] Email #{communication.id} opened"
      end
      
      # Serve 1x1 transparent GIF
      send_data(
        Base64.decode64('R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7'),
        type: 'image/gif',
        disposition: 'inline'
      )
    rescue => e
      Rails.logger.error "[EmailTracking] Error: #{e.message}"
      head :ok  # Always return 200 to avoid errors in email client
    end
  end
end
```

### File 2: webhooks/twilio_controller.rb

```ruby
# frozen_string_literal: true

module Webhooks
  class TwilioController < ApplicationController
    skip_before_action :verify_authenticity_token
    skip_before_action :authenticate_user!
    
    # POST /webhooks/twilio/sms/status
    def sms_status
      message_sid = params['MessageSid']
      status = params['MessageStatus']
      
      Rails.logger.info "[Twilio] Webhook received: SID=#{message_sid}, Status=#{status}"
      
      # Find communication by external_id (Twilio message SID)
      communication = Communication.find_by(external_id: message_sid)
      
      unless communication
        Rails.logger.warn "[Twilio] Communication not found for SID: #{message_sid}"
        return head :ok
      end
      
      case status
      when 'sent'
        communication.update!(sent_at: Time.current) unless communication.sent_at
        CommunicationEvent.track_send(communication, details: twilio_params)
        
      when 'delivered'
        communication.update!(
          status: 'delivered',
          delivered_at: Time.current
        )
        CommunicationEvent.track_delivery(communication, details: twilio_params)
        Rails.logger.info "[Twilio] SMS #{communication.id} delivered"
        
      when 'undelivered', 'failed'
        error_code = params['ErrorCode']
        error_message = params['ErrorMessage'] || 'Unknown error'
        
        communication.mark_as_failed!("Twilio Error #{error_code}: #{error_message}")
        CommunicationEvent.track_failure(
          communication,
          error: error_message,
          details: twilio_params
        )
        Rails.logger.error "[Twilio] SMS #{communication.id} failed: #{error_message}"
      end
      
      head :ok
    rescue => e
      Rails.logger.error "[Twilio] Webhook error: #{e.message}"
      Rails.logger.error e.backtrace.first(5).join("\n")
      head :ok  # Always return 200 to Twilio
    end
    
    private
    
    def twilio_params
      {
        message_sid: params['MessageSid'],
        from: params['From'],
        to: params['To'],
        status: params['MessageStatus'],
        error_code: params['ErrorCode'],
        error_message: params['ErrorMessage'],
        price: params['Price'],
        price_unit: params['PriceUnit']
      }.compact
    end
  end
end
```

### File 3: Update Communication Model

Add these helper methods to `app/models/communication.rb`:

```ruby
# After the existing mark_as_* methods

def mark_as_opened!(ip_address: nil, user_agent: nil)
  return if read_at.present?  # Already opened
  
  update!(read_at: Time.current)
  track_event('opened', ip_address: ip_address, user_agent: user_agent)
end

def mark_as_clicked!(url:, ip_address: nil, user_agent: nil)
  track_event('clicked', url: url, ip_address: ip_address, user_agent: user_agent)
end

# Update existing delivered method to also track event
def mark_as_delivered!
  return if delivered_at.present?  # Already marked
  
  update!(status: 'delivered', delivered_at: Time.current)
  track_event('delivered')
end
```

### File 4: Update platform/communications_controller.rb

Modify the `send_email_via_action_mailer` method:

```ruby
def send_email_via_action_mailer(email_params, config)
  from_email = config['fromEmail'] || config[:fromEmail]
  from_name = config['fromName'] || config[:fromName] || 'RenterInsight'
  
  # ⚠️ IMPORTANT: Create the communication BEFORE sending
  # so we have an ID for the tracking pixel
  communication_id = create_pending_communication(email_params, config) if params[:entity_id]
  
  # Add tracking pixel to email body
  enhanced_body = email_params[:content]
  if communication_id
    enhanced_body = add_tracking_pixel(email_params[:content], communication_id)
  end
  
  Rails.logger.info "[send_email_via_action_mailer] Sending to #{email_params[:to]} from #{from_email}"
  
  mail = CommunicationMailer.send_communication(
    to: email_params[:to],
    subject: email_params[:subject],
    body: enhanced_body,  # ← Use enhanced body with pixel
    from_email: from_email,
    from_name: from_name,
    cc: email_params[:cc],
    bcc: email_params[:bcc]
  )
  
  mail.deliver_now
  
  # Update communication with message ID
  if communication_id
    comm = Communication.find(communication_id)
    comm.update!(
      status: 'sent',
      sent_at: Time.current,
      external_id: mail.message_id
    )
    CommunicationEvent.track_send(comm, details: { message_id: mail.message_id })
  end
  
  Rails.logger.info "[send_email_via_action_mailer] Success: #{mail.message_id}"
  { 
    success: true, 
    message_id: mail.message_id,
    communication_id: communication_id
  }
rescue => e
  Rails.logger.error "[send_email_via_action_mailer] Exception: #{e.message}"
  Rails.logger.error(e.backtrace.first(5).join("\n"))
  { success: false, error: e.message }
end

private

def create_pending_communication(email_params, config)
  entity_type = params[:entity_type]
  entity_id = params[:entity_id]
  return nil unless entity_type && entity_id
  
  entity = entity_type.constantize.find_by(id: entity_id)
  return nil unless entity
  
  log = Communication.create!(
    communicable: entity,
    channel: 'email',
    direction: 'outbound',
    subject: email_params[:subject],
    body: email_params[:content],
    status: 'pending',  # Will be updated to 'sent' after delivery
    to_address: email_params[:to],
    from_address: config['fromEmail'] || config[:fromEmail],
    metadata: {
      provider: config['provider'] || config[:provider] || 'smtp',
      template_id: email_params[:template_id]
    }.compact
  )
  
  log.id
end

def add_tracking_pixel(body, communication_id)
  # Generate pixel URL
  pixel_url = Rails.application.routes.url_helpers.webhooks_email_pixel_url(
    communication_id: communication_id,
    host: ENV['APP_HOST'] || ENV['RAILS_HOST'] || 'localhost:3001',
    protocol: ENV['APP_PROTOCOL'] || 'http'
  )
  
  tracking_pixel = %(<img src="#{pixel_url}" width="1" height="1" alt="" style="display:none;border:0;" />)
  
  # Add pixel to HTML body
  if body.include?('</body>')
    body.gsub('</body>', "#{tracking_pixel}</body>")
  elsif body.include?('</html>')
    body.gsub('</html>', "#{tracking_pixel}</html>")
  else
    # Wrap plain text in HTML with pixel
    "<html><body>#{body}#{tracking_pixel}</body></html>"
  end
end
```

### File 5: Update SMS sending to store message_sid

In `send_sms_via_twilio` method:

```ruby
def send_sms_via_twilio(to, message, config)
  # ... existing code ...
  
  if response.code.to_i == 201
    message_sid = result['sid']
    
    # ⚠️ STORE THE MESSAGE SID AS external_id for webhook matching
    if params[:entity_id] && params[:entity_type]
      entity = params[:entity_type].constantize.find_by(id: params[:entity_id])
      
      if entity
        log = Communication.create!(
          communicable: entity,
          channel: 'sms',
          direction: 'outbound',
          body: message,
          status: 'sent',
          sent_at: Time.current,
          to_address: to,
          from_address: config['fromNumber'] || config[:fromNumber],
          external_id: message_sid,  # ← CRITICAL for webhook matching
          metadata: {
            provider: 'twilio',
            status: result['status']
          }
        )
      end
    end
    
    Rails.logger.info "[send_sms_via_twilio] Success: #{message_sid}"
    { 
      success: true, 
      message_sid: message_sid,
      status: result['status']
    }
  else
    # ... error handling ...
  end
end
```

---

## 🧪 Testing Plan

### Test 1: Email Tracking Pixel
1. Send an email to yourself
2. Check database: `Communication.last` should have an ID
3. Open the email
4. Check logs: Should see "[EmailTracking] Email X opened"
5. Check database: `Communication.last.read_at` should be set
6. Check: `CommunicationEvent.where(event_type: 'opened').last` should exist

### Test 2: SMS Delivery (Requires Twilio Configuration)
1. Configure Twilio webhook URL (use ngrok for local testing):
   ```bash
   ngrok http 3001
   # Use: https://abc123.ngrok.io/webhooks/twilio/sms/status
   ```
2. Send SMS
3. Check database: `Communication.last.external_id` should be Twilio SID
4. Wait for delivery (usually < 10 seconds)
5. Check logs: Should see "[Twilio] SMS X delivered"
6. Check database: `Communication.last.delivered_at` should be set

### Test 3: Failed SMS
1. Send SMS to invalid number (e.g., +1234567890)
2. Wait for Twilio webhook
3. Check: `Communication.last.status` should be 'failed'
4. Check: `Communication.last.error_message` should contain Twilio error

---

## 🚀 Deployment Steps

### Step 1: Add Webhook Routes
✅ Add routes to `config/routes.rb`

### Step 2: Create Controllers
✅ Create all webhook controller files

### Step 3: Update Communication Model
✅ Add tracking helper methods

### Step 4: Update Email Sending
✅ Add tracking pixel implementation

### Step 5: Update SMS Sending  
✅ Store external_id (message_sid)

### Step 6: Configure Twilio
1. Log into Twilio console
2. Go to Phone Numbers → Active Numbers
3. Click your SMS-enabled number
4. Scroll to "Messaging Configuration"
5. Set Status Callback URL: `https://yourdomain.com/webhooks/twilio/sms/status`
6. Method: HTTP POST
7. Click Save

### Step 7: Set Environment Variables
```bash
# .env or deployment config
APP_HOST=yourdomain.com
APP_PROTOCOL=https
```

### Step 8: Test Everything
Run all test cases above

---

## 📊 Expected Results

After full implementation:

### Email Opens:
- ✅ 1x1 pixel embedded in every outbound email
- ✅ When recipient opens email, pixel loads
- ✅ `read_at` timestamp set automatically
- ✅ `CommunicationEvent` created with type 'opened'
- ✅ Frontend UI shows: "👁️ Read Oct 20, 2025 10:45 AM"

### SMS Delivery:
- ✅ Twilio sends webhook when SMS delivered
- ✅ `delivered_at` timestamp set automatically  
- ✅ `CommunicationEvent` created with type 'delivered'
- ✅ Frontend UI shows: "✓ Delivered Oct 20, 2025 10:31 AM"

### Failed Messages:
- ✅ Status updated to 'failed'
- ✅ Error message captured
- ✅ `CommunicationEvent` created with error details

---

## 🔒 Security Considerations

### Webhook Security:
1. **Twilio**: Verify webhook signature (optional, recommended for production)
2. **Tracking Pixel**: No auth needed (it's in emails)
3. **Rate Limiting**: Consider rate limits on webhook endpoints
4. **HTTPS Only**: Use HTTPS in production for all webhooks

### Example: Twilio Signature Verification (Optional)
```ruby
def verify_twilio_signature
  auth_token = ENV['TWILIO_AUTH_TOKEN']
  signature = request.headers['X-Twilio-Signature']
  
  validator = Twilio::Security::RequestValidator.new(auth_token)
  url = request.original_url
  
  unless validator.validate(url, params.to_unsafe_h, signature)
    Rails.logger.error "[Twilio] Invalid webhook signature"
    head :forbidden
    return false
  end
  
  true
end
```

---

## 💡 Future Enhancements

Not in current scope, but possible additions:

- Email click tracking (wrap links with tracking URLs)
- Link-specific analytics
- Email client detection (Gmail, Outlook, Apple Mail)
- Geographic tracking (IP geolocation)
- SendGrid/Mailgun webhook handlers for better email tracking
- Bounce handling and auto-unsubscribe
- Real-time WebSocket updates when events arrive
- Dashboard widget showing aggregate open/delivery rates

---

## ✅ Summary

**Scope**: Complete email and SMS tracking implementation

**Files to Create/Modify**:
- ✅ webhooks/email_tracking_controller.rb (new)
- ✅ webhooks/twilio_controller.rb (new)
- ✅ config/routes.rb (add webhook routes)
- ✅ app/models/communication.rb (add helper methods)
- ✅ api/platform/communications_controller.rb (add tracking pixel)

**External Configuration**:
- ✅ Twilio webhook URL configuration

**Time Estimate**: 2-3 hours

**Testing Time**: 1 hour

**Ready to implement!** 🚀

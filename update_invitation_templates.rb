#!/usr/bin/env ruby
# Script to update company user invitation templates in staging/production
# Run with: bundle exec rails runner update_invitation_templates.rb

puts "🔄 Updating Company User Invitation Templates..."
puts "=" * 80

# Delete old templates with incorrect merge variables
deleted_email = CommunicationTemplate.where(
  template_type: 'company_user_invitation',
  channel: 'email'
).delete_all

deleted_sms = CommunicationTemplate.where(
  template_type: 'company_user_invitation',
  channel: 'sms'
).delete_all

puts "✅ Deleted #{deleted_email} old email template(s)"
puts "✅ Deleted #{deleted_sms} old SMS template(s)"
puts ""

# Create new EMAIL template with correct variables
email_template = CommunicationTemplate.create!(
  name: 'Company User Invitation - Email',
  description: 'Default email template for inviting new users to join your company',
  subject: 'Welcome to {{ company_name }} - Set Up Your Account',
  body: <<~HTML,
    <html>
    <head>
      <style>
        body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
        .container { max-width: 600px; margin: 0 auto; padding: 20px; }
        .header { background-color: #4F46E5; color: white; padding: 20px; text-align: center; border-radius: 8px 8px 0 0; }
        .content { background-color: #f9fafb; padding: 30px; border-radius: 0 0 8px 8px; }
        .button { display: inline-block; background-color: #4F46E5; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; margin: 20px 0; }
        .info-box { background-color: #e0e7ff; border-left: 4px solid #4F46E5; padding: 15px; margin: 20px 0; }
        .footer { text-align: center; margin-top: 30px; font-size: 12px; color: #6b7280; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Welcome to {{ company_name }}!</h1>
        </div>
        <div class="content">
          <p>Hi {{ first_name }},</p>
          
          <p>{{ invited_by }} has invited you to join <strong>{{ company_name }}</strong> on Platform DMS.</p>
          
          <div class="info-box">
            <p><strong>Your Role:</strong> {{ role_name }}</p>
            <p><strong>Email:</strong> {{ email }}</p>
          </div>
          
          <p>To get started, please click the button below to set up your password and access your account:</p>
          
          <div style="text-align: center;">
            <a href="{{ invitation_url }}" class="button">Set Up My Account</a>
          </div>
          
          <p><small>Or copy and paste this link into your browser:<br>
          {{ invitation_url }}</small></p>
          
          <div class="info-box">
            <p><strong>⏰ Important:</strong> This invitation expires on {{ invitation_expires }}. Please complete your registration before then.</p>
          </div>
          
          <p>If you have any questions or need assistance, please contact your administrator at {{ company_name }}.</p>
          
          <p>We're excited to have you on board!</p>
          
          <p>Best regards,<br>
          The {{ company_name }} Team</p>
        </div>
        <div class="footer">
          <p>© {{ company_name }} | Platform DMS</p>
          <p>This is an automated message. Please do not reply to this email.</p>
        </div>
      </div>
    </body>
    </html>
  HTML
  is_active: true,
  is_default: true,
  template_type: 'company_user_invitation',
  channel: 'email'
)

puts "✅ Created new EMAIL template (ID: #{email_template.id})"
puts "   - Uses {{ invitation_url }} instead of {{ login_url }}"
puts "   - Uses {{ first_name }}, {{ invited_by }} instead of {{ user_name }}, {{ admin_name }}"
puts ""

# Create new SMS template with correct variables
sms_template = CommunicationTemplate.create!(
  name: 'Company User Invitation - SMS',
  description: 'Default SMS template for inviting new users to join your company',
  subject: nil, # SMS doesn't have subject
  body: <<~SMS.strip,
    Hi {{ first_name }}! {{ invited_by }} invited you to join {{ company_name }} on Platform DMS as {{ role_name }}.
    
    Set up your account: {{ invitation_url }}
    
    Link expires {{ days_until_expiry }} days. Questions? Contact your admin.
  SMS
  is_active: true,
  is_default: true,
  template_type: 'company_user_invitation',
  channel: 'sms'
)

puts "✅ Created new SMS template (ID: #{sms_template.id})"
puts "   - Uses {{ invitation_url }} instead of {{ login_url }}"
puts "   - Uses {{ first_name }}, {{ invited_by }} instead of {{ user_name }}, {{ admin_name }}"
puts ""

puts "=" * 80
puts "✨ Template update complete!"
puts ""
puts "📋 Summary of changes:"
puts "  • Removed {{ admin_name }} → use {{ invited_by }}"
puts "  • Removed {{ admin_email }} → no longer needed"
puts "  • Removed {{ user_name }} → use {{ first_name }} or {{ recipient_name }}"
puts "  • Changed {{ login_url }} → {{ invitation_url }} (CRITICAL!)"
puts ""
puts "🎯 The invitation links will now go to:"
puts "   /invitations/accept?token=..."
puts "   instead of /login"
puts ""
puts "✅ Ready to test!"

# frozen_string_literal: true

# Seed default communication templates for company user invitations

puts "🌱 Seeding Company User Invitation Templates..."

# Email Invitation Template
email_template = CommunicationTemplate.find_or_initialize_by(
  template_type: 'company_user_invitation',
  channel: 'email',
  name: 'Company User Invitation - Email'
)

email_template.assign_attributes(
  subject: 'Welcome to {{ company_name }} - Set Up Your Account',
  body: <<~BODY,
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <style>
        body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
        .container { max-width: 600px; margin: 0 auto; padding: 20px; }
        .header { background: #4F46E5; color: white; padding: 20px; text-align: center; border-radius: 8px 8px 0 0; }
        .content { background: #ffffff; padding: 30px; border: 1px solid #e5e7eb; border-top: none; }
        .button { display: inline-block; padding: 14px 32px; background: #4F46E5; color: white; text-decoration: none; border-radius: 6px; font-weight: bold; margin: 20px 0; }
        .button:hover { background: #4338CA; }
        .footer { padding: 20px; text-align: center; color: #6b7280; font-size: 14px; }
        .steps { background: #f9fafb; padding: 15px; border-left: 4px solid #4F46E5; margin: 20px 0; }
        .expires { background: #fef3c7; padding: 10px; border-radius: 4px; margin: 15px 0; }
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>Welcome to {{ company_name }}!</h1>
        </div>
        <div class="content">
          <p>Hi {{ recipient_name }},</p>
          
          <p>Your account has been created and you've been assigned the role of <strong>{{ role }}</strong>.</p>
          
          <p>To get started, click the button below to set up your password and access your account:</p>
          
          <div style="text-align: center;">
            <a href="{{ invitation_url }}" class="button">Create Account</a>
          </div>
          
          <div class="expires">
            <strong>⏰ This invitation expires on {{ expires_at }}</strong>
          </div>
          
          <div class="steps">
            <h3>Next Steps:</h3>
            <ol>
              <li>Click the "Create Account" button above</li>
              <li>Create a secure password</li>
              <li>Log in to your account</li>
            </ol>
          </div>
          
          <p>If you have any questions or need assistance, please contact {{ invited_by }}.</p>
          
          <p>Best regards,<br>The {{ company_name }} Team</p>
        </div>
        <div class="footer">
          <p>If the button doesn't work, copy and paste this link into your browser:</p>
          <p style="word-break: break-all;">{{ invitation_url }}</p>
        </div>
      </div>
    </body>
    </html>
  BODY
  is_active: true,
  company_id: nil
)

if email_template.save
  puts "✅ Created/Updated: #{email_template.name}"
else
  puts "❌ Failed to create email template: #{email_template.errors.full_messages.join(', ')}"
end

# SMS Invitation Template
sms_template = CommunicationTemplate.find_or_initialize_by(
  template_type: 'company_user_invitation',
  channel: 'sms',
  name: 'Company User Invitation - SMS'
)

sms_template.assign_attributes(
  body: 'Hi {{ recipient_name }}! Your {{ company_name }} account is ready. Set up your password: {{ invitation_url }}',
  is_active: true,
  company_id: nil
)

if sms_template.save
  puts "✅ Created/Updated: #{sms_template.name}"
else
  puts "❌ Failed to create SMS template: #{sms_template.errors.full_messages.join(', ')}"
end

puts "✨ Company User Invitation templates seeded successfully!"

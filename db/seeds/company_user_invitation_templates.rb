# Seeds for Company User Invitation Templates
# These templates are used when inviting new users to join a company

puts "🌱 Seeding Company User Invitation templates..."

# Email Template for Company User Invitation
# Delete old template and create fresh one
CommunicationTemplate.where(
  template_type: 'company_user_invitation',
  channel: 'email'
).destroy_all

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

puts "✅ Created Email template for company_user_invitation"

# SMS Template for Company User Invitation
# Delete old template and create fresh one
CommunicationTemplate.where(
  template_type: 'company_user_invitation',
  channel: 'sms'
).destroy_all

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

puts "✅ Created SMS template for company_user_invitation"

puts "✨ Company User Invitation template seeding complete!"

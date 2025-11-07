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
  subject: 'You\'re Invited to Join {{company_name}} - Set Up Your Account',
  body: <<~HTML.strip,
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <style>
        body {
          font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, 'Helvetica Neue', Arial, sans-serif;
          line-height: 1.6;
          color: #1f2937;
          margin: 0;
          padding: 0;
          background-color: #f3f4f6;
        }
        .email-wrapper {
          max-width: 600px;
          margin: 40px auto;
          background-color: #ffffff;
          border-radius: 12px;
          overflow: hidden;
          box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
        }
        .header {
          background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
          color: white;
          padding: 40px 30px;
          text-align: center;
        }
        .header h1 {
          margin: 0;
          font-size: 28px;
          font-weight: 700;
          letter-spacing: -0.5px;
        }
        .header p {
          margin: 10px 0 0 0;
          font-size: 16px;
          opacity: 0.95;
        }
        .content {
          padding: 40px 30px;
        }
        .greeting {
          font-size: 18px;
          color: #111827;
          margin-bottom: 20px;
        }
        .intro-text {
          font-size: 16px;
          color: #4b5563;
          margin-bottom: 25px;
        }
        .info-card {
          background-color: #f9fafb;
          border-left: 4px solid #667eea;
          padding: 20px;
          margin: 25px 0;
          border-radius: 6px;
        }
        .info-card p {
          margin: 8px 0;
          font-size: 15px;
        }
        .info-card strong {
          color: #111827;
          font-weight: 600;
        }
        .cta-container {
          text-align: center;
          margin: 35px 0;
        }
        .cta-button {
          display: inline-block;
          background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
          color: white;
          padding: 16px 40px;
          text-decoration: none;
          border-radius: 8px;
          font-size: 16px;
          font-weight: 600;
          box-shadow: 0 4px 12px rgba(102, 126, 234, 0.4);
          transition: transform 0.2s;
        }
        .cta-button:hover {
          transform: translateY(-2px);
        }
        .alt-link {
          text-align: center;
          margin: 20px 0;
          font-size: 13px;
          color: #6b7280;
        }
        .alt-link a {
          color: #667eea;
          word-break: break-all;
        }
        .warning-box {
          background-color: #fef3c7;
          border-left: 4px solid #f59e0b;
          padding: 15px 20px;
          margin: 25px 0;
          border-radius: 6px;
        }
        .warning-box p {
          margin: 0;
          font-size: 14px;
          color: #92400e;
        }
        .warning-box strong {
          font-weight: 600;
        }
        .setup-instructions {
          background-color: #eff6ff;
          border-radius: 8px;
          padding: 20px;
          margin: 25px 0;
        }
        .setup-instructions h3 {
          margin: 0 0 15px 0;
          color: #1e40af;
          font-size: 16px;
        }
        .setup-instructions ol {
          margin: 0;
          padding-left: 20px;
        }
        .setup-instructions li {
          margin: 8px 0;
          font-size: 14px;
          color: #1e40af;
        }
        .footer {
          background-color: #f9fafb;
          padding: 30px;
          text-align: center;
          border-top: 1px solid #e5e7eb;
        }
        .footer p {
          margin: 5px 0;
          font-size: 13px;
          color: #6b7280;
        }
        .signature {
          margin-top: 30px;
          padding-top: 20px;
          border-top: 1px solid #e5e7eb;
        }
        @media only screen and (max-width: 600px) {
          .email-wrapper {
            margin: 0;
            border-radius: 0;
          }
          .header, .content, .footer {
            padding: 25px 20px;
          }
          .cta-button {
            padding: 14px 30px;
            font-size: 15px;
          }
        }
      </style>
    </head>
    <body>
      <div class="email-wrapper">
        <div class="header">
          <h1>🎉 Welcome to {{company_name}}!</h1>
          <p>You've been invited to join our team</p>
        </div>
        
        <div class="content">
          <div class="greeting">
            Hi {{first_name}},
          </div>
          
          <p class="intro-text">
            <strong>{{invited_by}}</strong> has invited you to join <strong>{{company_name}}</strong> on our property management platform. We're excited to have you as part of the team!
          </p>
          
          <div class="info-card">
            <p><strong>📧 Email:</strong> {{email}}</p>
            <p><strong>👤 Role:</strong> {{role_name}}</p>
            <p><strong>👋 Invited By:</strong> {{invited_by}}</p>
          </div>
          
          <div class="setup-instructions">
            <h3>📋 Getting Started:</h3>
            <ol>
              <li>Click the button below to access the registration page</li>
              <li>Create a secure password for your account</li>
              <li>Complete your profile information</li>
              <li>Start managing properties and collaborating with your team!</li>
            </ol>
          </div>
          
          <div class="cta-container">
            <a href="{{invitation_url}}" class="cta-button">
              Set Up My Account →
            </a>
          </div>
          
          <div class="alt-link">
            <p>Or copy and paste this link into your browser:</p>
            <a href="{{invitation_url}}">{{invitation_url}}</a>
          </div>
          
          <div class="warning-box">
            <p><strong>⏰ Time Sensitive:</strong> This invitation expires on <strong>{{invitation_expires}}</strong>. Please complete your registration before the link expires.</p>
          </div>
          
          <p class="intro-text">
            If you have any questions or need assistance getting started, don't hesitate to reach out to your administrator or our support team.
          </p>
          
          <div class="signature">
            <p>Best regards,</p>
            <p><strong>The {{company_name}} Team</strong></p>
          </div>
        </div>
        
        <div class="footer">
          <p><strong>{{company_name}}</strong></p>
          <p>Property Management Platform</p>
          <p style="margin-top: 15px;">This is an automated invitation email. Please do not reply directly to this message.</p>
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

puts "✅ Created professional HTML email template for company_user_invitation"

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
    {{first_name}}, join {{company_name}}: {{invitation_url}} ({{role_name}}, exp {{days_until_expiry}}d)
  SMS
  is_active: true,
  is_default: true,
  template_type: 'company_user_invitation',
  channel: 'sms'
)

puts "✅ Created professional SMS template for company_user_invitation"

puts "✨ Company User Invitation template seeding complete!"

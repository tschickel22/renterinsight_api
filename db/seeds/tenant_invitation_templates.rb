# Seeds for Tenant Invitation Templates
# These templates are used when inviting new tenant/company owners to the platform

puts "🌱 Seeding Tenant Invitation templates..."

# Email Template for Tenant Invitation
# Delete old template and create fresh one
CommunicationTemplate.where(
  template_type: 'tenant_invitation',
  channel: 'email'
).destroy_all

email_template = CommunicationTemplate.create!(
  name: 'Tenant Invitation - Email',
  description: 'Professional email template for inviting new tenant/company owners to the platform',
  subject: 'Welcome to {{platform_name}} - Your Account is Ready',
  body: <<~HTML.strip,
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width,initial-scale=1" />
        <title>Welcome to {{company_name}}</title>
        <style>
          /* ----- Reset (kept minimal for email clients) ----- */
          body, table, td, p, a { -webkit-text-size-adjust:100%; -ms-text-size-adjust:100%; }
          table, td { mso-table-lspace:0pt; mso-table-rspace:0pt; }
          img { -ms-interpolation-mode:bicubic; border:0; outline:none; text-decoration:none; display:block; }
          table { border-collapse:collapse !important; }
          body { margin:0; padding:0; width:100% !important; height:100% !important; }
          /* ----- Layout ----- */
          .bg { background:#f6f7fb; padding:24px; }
          .container { max-width:640px; margin:0 auto; background:#ffffff; border-radius:10px; overflow:hidden; }
          .header { padding:24px 24px 8px 24px; text-align:center; }
          .logo { width:200px; height:auto; margin:0 auto; }
          .content { padding:8px 24px 24px 24px; font-family: Arial, Helvetica, sans-serif; color:#222; }
          h1 { font-size:22px; line-height:1.3; margin:16px 0 8px; }
          p { font-size:15px; line-height:1.6; margin:0 0 16px; }
          .cta-wrap { text-align:center; margin:24px 0; }
          .btn { background:#d6422b; color:#ffffff !important; text-decoration:none; display:inline-block; padding:12px 22px; border-radius:8px; font-weight:bold; }
          .subtle { color:#666; font-size:13px; }
          .footer { text-align:center; padding:16px 24px 24px 24px; color:#888; font-size:12px; font-family: Arial, Helvetica, sans-serif; }
          @media (prefers-color-scheme: dark) {
            .container { background:#161718; }
            .content { color:#f1f1f1; }
            .subtle { color:#c5c5c5; }
            .footer { color:#888; }
          }
        </style>
      </head>
      <body>
        <center>
          <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" class="bg">
            <tr>
              <td>
                <table role="presentation" class="container" cellspacing="0" cellpadding="0" border="0" width="100%">
                  <tr>
                    <td class="header">
                      <img src="{{platform_logo_url}}" alt="Logo" class="logo" />
                    </td>
                  </tr>
                  <tr>
                    <td class="content">
                      <h1>🎉 Welcome to {{platform_name}}</h1>
                      <p>We're excited to help you streamline your operations and get up and running quickly.</p>
                      <div class="cta-wrap">
                        <a href="{{invitation_url}}" class="btn" target="_blank" rel="noopener">Complete Account Setup</a>
                      </div>
                      <p class="subtle">If the button doesn't work, copy and paste this link into your browser:<br>
                        <a href="{{invitation_url}}" style="color:#d6422b;">{{invitation_url}}</a>
                      </p>
                      <p class="subtle">For security, your invitation link expires on {{invitation_expires}}. If you need a new link, request another from your administrator.</p>
                      <p class="subtle">Questions? Just reply to this email and our team will help.</p>
                    </td>
                  </tr>
                  <tr>
                    <td class="footer">
                      © {{current_year}} {{platform_name}}
                    </td>
                  </tr>
                </table>
              </td>
            </tr>
          </table>
        </center>
      </body>
    </html>
  HTML
  is_active: true,
  is_default: true,
  template_type: 'tenant_invitation',
  channel: 'email'
)

puts "✅ Created professional HTML email template for tenant_invitation"

# SMS Template for Tenant Invitation
# Delete old template and create fresh one
CommunicationTemplate.where(
  template_type: 'tenant_invitation',
  channel: 'sms'
).destroy_all

sms_template = CommunicationTemplate.create!(
  name: 'Tenant Invitation - SMS',
  description: 'SMS template for inviting new tenant/company owners to the platform',
  subject: nil, # SMS doesn't have subject
  body: <<~SMS.strip,
    {{first_name}}, welcome! Your {{company_name}} platform is ready. Complete setup: {{invitation_url}} (Expires {{days_until_expiry}}d)
  SMS
  is_active: true,
  is_default: true,
  template_type: 'tenant_invitation',
  channel: 'sms'
)

puts "✅ Created professional SMS template for tenant_invitation"

puts "✨ Tenant Invitation template seeding complete!"

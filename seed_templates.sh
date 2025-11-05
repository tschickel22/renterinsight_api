#!/bin/bash
# Script to seed communication templates

cd ~/src/renterinsight_api

echo "🌱 Seeding Company User Invitation Templates..."

bundle exec rails runner "
# Email Invitation Template
email_template = CommunicationTemplate.find_or_initialize_by(
  template_type: 'company_user_invitation',
  channel: 'email',
  name: 'Company User Invitation - Email'
)

email_template.assign_attributes(
  subject_template: 'Welcome to {{ company_name }} - Set Up Your Account',
  body_template: <<~BODY,
    Hi {{ user_name }},

    Welcome to {{ company_name }}! Your account has been created and you've been assigned the role of {{ role_name }}.

    To get started, please click the link below to set up your password and access your account:

    {{ login_url }}

    This invitation will expire on {{ invitation_expires }}. 

    Here are your next steps:
    1. Click the link above
    2. Create a secure password
    3. Log in to your account

    If you have any questions or need assistance, please contact {{ admin_name }} at {{ admin_email }}.

    Best regards,
    The {{ company_name }} Team
  BODY
  active: true,
  scope_type: 'Platform',
  scope_id: nil
)

if email_template.save
  puts '✅ Created/Updated: Company User Invitation - Email'
else
  puts \"❌ Failed to create email template: #{email_template.errors.full_messages.join(', ')}\"
end

# SMS Invitation Template
sms_template = CommunicationTemplate.find_or_initialize_by(
  template_type: 'company_user_invitation',
  channel: 'sms',
  name: 'Company User Invitation - SMS'
)

sms_template.assign_attributes(
  subject_template: nil,
  body_template: 'Hi {{ user_name }}! Your {{ company_name }} account is ready. Set up your password: {{ login_url }}',
  active: true,
  scope_type: 'Platform',
  scope_id: nil
)

if sms_template.save
  puts '✅ Created/Updated: Company User Invitation - SMS'
else
  puts \"❌ Failed to create SMS template: #{sms_template.errors.full_messages.join(', ')}\"
end

puts \"✨ Template seeding complete!\"
puts \"Total templates: #{CommunicationTemplate.where(template_type: 'company_user_invitation').count}\"
"

echo ""
echo "✨ Done! Templates created."

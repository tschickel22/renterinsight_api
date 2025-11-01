# frozen_string_literal: true

# This file should contain all the record creation needed to seed the database with its default values.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).

puts "🌱 Starting seed..."

# Only seed if CommunicationTemplate model exists
if defined?(CommunicationTemplate)
  puts "📧 Creating communication templates..."

  templates = [
    {
      name: "Company User Invitation - Email",
      template_type: "company_user_invitation",
      channel: "email",
      subject: "Welcome to {{company_name}} - Set Up Your Account",
      body: <<~BODY,
        Hello {{user_name}},

        Welcome to {{company_name}}! You've been invited to join our team.

        Please click the link below to set up your password and access the system:
        {{login_url}}

        This invitation will expire in {{invitation_expires}}.

        If you have any questions, please contact {{admin_name}} at {{admin_email}}.

        Best regards,
        The {{company_name}} Team
      BODY
      is_active: true,
      is_default: true,
      description: "Default email template for inviting company users"
    },
    {
      name: "Company User Invitation - SMS",
      template_type: "company_user_invitation",
      channel: "sms",
      subject: nil,
      body: "Welcome to {{company_name}}! You've been invited to join our team. Set up your account: {{login_url}}",
      is_active: true,
      is_default: true,
      description: "Default SMS template for inviting company users"
    },
    {
      name: "Password Reset - Email",
      template_type: "password_reset",
      channel: "email",
      subject: "Reset Your Password",
      body: <<~BODY,
        Hello {{user_name}},

        We received a request to reset your password. Click the link below to reset it:
        {{reset_link}}

        This link will expire in {{reset_expires}}.

        If you didn't request this, please ignore this email.

        Best regards,
        The Team
      BODY
      is_active: true,
      is_default: true,
      description: "Default email template for password reset"
    },
    {
      name: "Password Reset - SMS",
      template_type: "password_reset",
      channel: "sms",
      subject: nil,
      body: "Reset your password: {{reset_link}} (expires in {{reset_expires}})",
      is_active: true,
      is_default: true,
      description: "Default SMS template for password reset"
    }
  ]

  templates.each do |template_data|
    template = CommunicationTemplate.find_or_create_by!(
      template_type: template_data[:template_type],
      channel: template_data[:channel],
      is_default: true
    ) do |t|
      t.name = template_data[:name]
      t.subject = template_data[:subject]
      t.body = template_data[:body]
      t.is_active = template_data[:is_active]
      t.description = template_data[:description]
    end
    
    puts "  ✅ #{template.persisted? ? 'Found' : 'Created'}: #{template.name}"
  end

  puts "✨ Template seed completed!"
else
  puts "⚠️  CommunicationTemplate model not found, skipping template seed"
end

puts "✨ Seed completed!"

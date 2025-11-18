# frozen_string_literal: true

# Seed default invitation templates for Platform
puts "🌱 Seeding Invitation Templates..."

# Company User Invitation - Email
CommunicationTemplate.find_or_create_by!(
  name: 'Company User Invitation - Email',
  template_type: 'company_user_invitation',
  channel: 'email',
  company_id: nil
) do |t|
  t.subject = 'You\'re Invited to Join {{ company_name }} on Platform DMS'
  t.body = <<~HTML
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
      <h2>Hello {{ recipient_name }},</h2>
      
      <p>{{ invited_by }} has invited you to join <strong>{{ company_name }}</strong> on Platform DMS.</p>
      
      <p><strong>Your Role:</strong> {{ role }}</p>
      
      <p>Click the button below to accept the invitation and set up your account:</p>
      
      <div style="text-align: center; margin: 30px 0;">
        <a href="{{ invitation_url }}" 
           style="background: #4f46e5; color: white; padding: 12px 30px; text-decoration: none; border-radius: 5px; display: inline-block;">
          Accept Invitation
        </a>
      </div>
      
      <p style="color: #666; font-size: 12px;">
        This invitation expires on {{ expires_at }}.
      </p>
      
      <p style="color: #666; font-size: 12px;">
        If you can't click the button, copy and paste this link into your browser:<br>
        <a href="{{ invitation_url }}">{{ invitation_url }}</a>
      </p>
    </div>
  HTML
  t.is_active = true
end

# Company User Invitation - SMS
CommunicationTemplate.find_or_create_by!(
  name: 'Company User Invitation - SMS',
  template_type: 'company_user_invitation',
  channel: 'sms',
  company_id: nil
) do |t|
  t.body = "{{ invited_by }} invited you to join {{ company_name }} on Platform DMS. Accept: {{ invitation_url }}"
  t.is_active = true
end

# Portal User Invitation - Email
CommunicationTemplate.find_or_create_by!(
  name: 'Portal User Invitation - Email',
  template_type: 'portal_user_invitation',
  channel: 'email',
  company_id: nil
) do |t|
  t.subject = 'Access Your Client Portal - {{ company_name }}'
  t.body = <<~HTML
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
      <h2>Hello {{ recipient_name }},</h2>
      
      <p>{{ invited_by }} from <strong>{{ company_name }}</strong> has invited you to access your client portal.</p>
      
      <p>Through the client portal, you can:</p>
      <ul>
        <li>View and manage your quotes</li>
        <li>Upload and access documents</li>
        <li>Communicate directly with our team</li>
        <li>Track the status of your requests</li>
      </ul>
      
      <p>Click the button below to activate your portal access and set your password:</p>
      
      <div style="text-align: center; margin: 30px 0;">
        <a href="{{ invitation_url }}" 
           style="background: #10b981; color: white; padding: 12px 30px; text-decoration: none; border-radius: 5px; display: inline-block;">
          Activate Portal Access
        </a>
      </div>
      
      <p style="color: #666; font-size: 12px;">
        This invitation expires on {{ expires_at }}.
      </p>
      
      <p style="color: #666; font-size: 12px;">
        If you can't click the button, copy and paste this link into your browser:<br>
        <a href="{{ invitation_url }}">{{ invitation_url }}</a>
      </p>
    </div>
  HTML
  t.is_active = true
end

# Portal User Invitation - SMS
CommunicationTemplate.find_or_create_by!(
  name: 'Portal User Invitation - SMS',
  template_type: 'portal_user_invitation',
  channel: 'sms',
  company_id: nil
) do |t|
  t.body = "{{ company_name }}: Access your client portal. Activate: {{ invitation_url }}"
  t.is_active = true
end

# Tenant Invitation - Email
CommunicationTemplate.find_or_create_by!(
  name: 'Tenant Invitation - Email',
  template_type: 'tenant_invitation',
  channel: 'email',
  company_id: nil
) do |t|
  t.subject = 'Welcome to Platform DMS - Set Up Your Company Account'
  t.body = <<~HTML
    <div style="font-family: Arial, sans-serif; max-width: 600px; margin: 0 auto;">
      <h2>Welcome to Platform DMS!</h2>
      
      <p>Hello {{ recipient_name }},</p>
      
      <p>{{ invited_by }} has invited you to set up a new company account on Platform DMS.</p>
      
      <p>Platform DMS is a comprehensive rental management system that will help you:</p>
      <ul>
        <li>Manage your inventory and quotes</li>
        <li>Track leads and customer relationships</li>
        <li>Streamline communications</li>
        <li>Generate insights and reports</li>
      </ul>
      
      <p>Click the button below to complete your company setup:</p>
      
      <div style="text-align: center; margin: 30px 0;">
        <a href="{{ invitation_url }}" 
           style="background: #f59e0b; color: white; padding: 12px 30px; text-decoration: none; border-radius: 5px; display: inline-block;">
          Complete Setup
        </a>
      </div>
      
      <p style="color: #666; font-size: 12px;">
        This invitation expires on {{ expires_at }}.
      </p>
      
      <p style="color: #666; font-size: 12px;">
        If you can't click the button, copy and paste this link into your browser:<br>
        <a href="{{ invitation_url }}">{{ invitation_url }}</a>
      </p>
    </div>
  HTML
  t.is_active = true
end

# Tenant Invitation - SMS
CommunicationTemplate.find_or_create_by!(
  name: 'Tenant Invitation - SMS',
  template_type: 'tenant_invitation',
  channel: 'sms',
  company_id: nil
) do |t|
  t.body = "Welcome to Platform DMS! Set up your company account: {{ invitation_url }}"
  t.is_active = true
end

puts "✅ Invitation templates seeded successfully!"
puts "   - Company User Invitation (Email & SMS)"
puts "   - Portal User Invitation (Email & SMS)"
puts "   - Tenant Invitation (Email & SMS)"

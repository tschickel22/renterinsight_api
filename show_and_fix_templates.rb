#!/usr/bin/env ruby
# Show and fix custom invitation templates

require_relative 'config/environment'

puts "\n" + "="*60
puts "🔍 YOUR CUSTOM INVITATION TEMPLATES"
puts "="*60

email_template = CommunicationTemplate.find(16)
sms_template = CommunicationTemplate.find(17)

puts "\n📧 EMAIL Template (ID: 16) - Current Content:"
puts "-"*60
puts "Subject: #{email_template.subject}"
puts "\nBody:"
puts email_template.body
puts "-"*60

puts "\n📱 SMS Template (ID: 17) - Current Content:"
puts "-"*60
puts sms_template.body
puts "-"*60

puts "\n" + "="*60
puts "🔧 FIXING YOUR TEMPLATES"
puts "="*60

# Check if templates need fixing
needs_fix = false

unless email_template.body.include?('{{ invitation_url }}')
  puts "\n❌ Email template is missing {{ invitation_url }} variable"
  needs_fix = true
else
  puts "\n✅ Email template has {{ invitation_url }}"
end

unless sms_template.body.include?('{{ invitation_url }}')
  puts "❌ SMS template is missing {{ invitation_url }} variable"
  needs_fix = true
else
  puts "✅ SMS template has {{ invitation_url }}"
end

if needs_fix
  puts "\n⚠️  YOUR TEMPLATES NEED TO INCLUDE THE INVITATION URL!"
  puts "\n💡 You have TWO options:"
  puts "\n1. Edit templates in the UI (Template Builder):"
  puts "   - Add this to your email body: {{ invitation_url }}"
  puts "   - Add this to your SMS body: {{ invitation_url }}"
  
  puts "\n2. Let me auto-fix them with a complete template:"
  puts "   - This will replace your current templates with proper ones"
  
  print "\n❓ Do you want me to auto-fix them? (yes/no): "
  response = gets.chomp.downcase
  
  if response == 'yes' || response == 'y'
    # Fix email template
    new_email_body = <<~HTML
      <html>
      <head>
        <style>
          body { font-family: Arial, sans-serif; line-height: 1.6; color: #333; }
          .container { max-width: 600px; margin: 0 auto; padding: 20px; }
          .header { background-color: #4F46E5; color: white; padding: 20px; text-align: center; border-radius: 8px 8px 0 0; }
          .content { background-color: #f9fafb; padding: 30px; border-radius: 0 0 8px 8px; }
          .button { display: inline-block; background-color: #4F46E5; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; margin: 20px 0; }
          .info-box { background-color: #e0e7ff; border-left: 4px solid #4F46E5; padding: 15px; margin: 20px 0; }
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
        </div>
      </body>
      </html>
    HTML
    
    new_sms_body = "Hi {{ first_name }}! {{ invited_by }} invited you to join {{ company_name }} as {{ role_name }}. Set up your account: {{ invitation_url }} - Expires {{ days_until_expiry }} days."
    
    if email_template.update(
      subject: "Welcome to {{ company_name }} - Set Up Your Account",
      body: new_email_body
    )
      puts "\n✅ Email template updated!"
    else
      puts "\n❌ Failed to update email template: #{email_template.errors.full_messages.join(', ')}"
    end
    
    if sms_template.update(body: new_sms_body)
      puts "✅ SMS template updated!"
    else
      puts "❌ Failed to update SMS template: #{sms_template.errors.full_messages.join(', ')}"
    end
    
    puts "\n✨ Templates fixed! Restart Rails server and resend invitation."
  else
    puts "\n👍 No problem! Edit your templates manually in the Template Builder."
    puts "   Make sure to add {{ invitation_url }} to the body!"
  end
else
  puts "\n✅ Your templates look good!"
end

puts "\n"

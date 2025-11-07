#!/usr/bin/env ruby
# Update your custom template with proper invitation URL

require_relative 'config/environment'

puts "\n" + "="*60
puts "🔧 UPDATING YOUR CUSTOM INVITATION TEMPLATE"
puts "="*60

email_template = CommunicationTemplate.find(16)

puts "\n📧 Current Email Template (ID: 16):"
puts "-"*60
puts "Name: #{email_template.name}"
puts "Subject: #{email_template.subject}"
puts "\nCurrent Body:"
puts email_template.body
puts "-"*60

puts "\n" + "="*60
puts "💡 OPTIONS"
puts "="*60
puts "\n1. Add JUST the invitation URL to your existing template"
puts "2. Replace with a complete professional template"
puts "3. Exit without changes"

print "\nYour choice (1/2/3): "
choice = gets.chomp

case choice
when "1"
  # Just append the URL to existing template
  new_body = email_template.body + "\n\n<p><strong>Click here to set up your account:</strong></p>\n<p><a href=\"{{ invitation_url }}\" style=\"background-color: #4F46E5; color: white; padding: 12px 24px; text-decoration: none; border-radius: 6px; display: inline-block;\">Set Up My Account</a></p>\n\n<p><small>Or copy this link: {{ invitation_url }}</small></p>"
  
  if email_template.update(body: new_body)
    puts "\n✅ Updated! Added invitation URL button to your template"
  else
    puts "\n❌ Failed: #{email_template.errors.full_messages.join(', ')}"
  end

when "2"
  # Replace with complete template
  new_body = <<~HTML
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
  
  if email_template.update(
    subject: "Welcome to {{ company_name }} - Set Up Your Account",
    body: new_body
  )
    puts "\n✅ Complete template installed!"
  else
    puts "\n❌ Failed: #{email_template.errors.full_messages.join(', ')}"
  end

when "3"
  puts "\n👍 No changes made"
  exit 0
else
  puts "\n❌ Invalid choice"
  exit 1
end

puts "\n" + "="*60
puts "✨ DONE!"
puts "="*60
puts "\nNext steps:"
puts "1. Restart Rails server (Ctrl+C, then: rails s)"
puts "2. Delete old invitations in Rails console:"
puts "   rails console"
puts "   Invitation.destroy_all"
puts "   exit"
puts "3. Send a new invitation from UI"
puts "4. Check email - should now have HTTPS URL!"
puts "\n"

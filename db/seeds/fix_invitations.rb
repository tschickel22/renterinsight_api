#!/usr/bin/env ruby
# frozen_string_literal: true

# Comprehensive Invitation System Check and Fix
# Run with: bundle exec rails runner db/seeds/fix_invitations.rb

puts "\n" + "="*80
puts "INVITATION SYSTEM CHECK & FIX"
puts "="*80 + "\n"

# Step 1: Seed Templates
puts "📝 Step 1: Seeding Communication Templates..."
puts "-"*80
load Rails.root.join('db', 'seeds', 'communication_templates_company_user.rb')

# Step 2: Verify Templates
puts "\n📋 Step 2: Verifying Templates in Database..."
puts "-"*80
email_template = CommunicationTemplate.find_by(
  template_type: 'company_user_invitation',
  channel: 'email'
)
sms_template = CommunicationTemplate.find_by(
  template_type: 'company_user_invitation',
  channel: 'sms'
)

if email_template
  puts "✅ Email template found (ID: #{email_template.id})"
  puts "   Name: #{email_template.name}"
  puts "   Active: #{email_template.active}"
  puts "   Has invitation_url: #{email_template.body_template.include?('{{ invitation_url }}')}"
  puts "   Has recipient_name: #{email_template.body_template.include?('{{ recipient_name }}')}"
else
  puts "❌ Email template NOT found!"
end

if sms_template
  puts "✅ SMS template found (ID: #{sms_template.id})"
  puts "   Name: #{sms_template.name}"
  puts "   Active: #{sms_template.active}"
  puts "   Has invitation_url: #{sms_template.body_template.include?('{{ invitation_url }}')}"
  puts "   Has recipient_name: #{sms_template.body_template.include?('{{ recipient_name }}')}"
else
  puts "❌ SMS template NOT found!"
end

# Step 3: Check Company
puts "\n🏢 Step 3: Checking Company..."
puts "-"*80
company = Company.first
if company
  puts "✅ Company found: #{company.name} (ID: #{company.id})"
else
  puts "⚠️  No company found. Creating default company..."
  company = Company.create!(name: 'Default Company')
  puts "✅ Created company: #{company.name} (ID: #{company.id})"
end

# Step 4: Check User
puts "\n👤 Step 4: Checking User..."
puts "-"*80
user = User.first
if user
  puts "✅ User found: #{user.name || user.email} (ID: #{user.id})"
  puts "   Email: #{user.email}"
  puts "   Role: #{user.role}"
else
  puts "❌ No user found! This is required."
  puts "   Run: bundle exec rails db:seed to create users"
end

# Step 5: Check Communication Settings
puts "\n⚙️  Step 5: Checking Communication Settings..."
puts "-"*80
settings_service = company ? 
  CommunicationSettingsService.for_company(company) : 
  CommunicationSettingsService.platform

email_config = settings_service.email_config
sms_config = settings_service.sms_config

puts "Email Configuration:"
puts "   From Email: #{email_config[:from_email] || 'NOT SET'}"
puts "   From Name: #{email_config[:from_name] || 'NOT SET'}"
puts "   Provider: #{ENV['DEFAULT_EMAIL_PROVIDER'] || 'smtp (default)'}"

puts "SMS Configuration:"
puts "   From Number: #{sms_config[:from_number] || 'NOT SET'}"
puts "   Provider: twilio"
puts "   Account SID: #{ENV['TWILIO_ACCOUNT_SID'] ? 'SET' : 'NOT SET'}"
puts "   Auth Token: #{ENV['TWILIO_AUTH_TOKEN'] ? 'SET' : 'NOT SET'}"

# Step 6: Check recent invitations
puts "\n📨 Step 6: Recent Invitations..."
puts "-"*80
recent_invitations = Invitation.order(created_at: :desc).limit(5)
if recent_invitations.any?
  puts "Found #{Invitation.count} total invitations. Most recent:"
  recent_invitations.each do |inv|
    puts "   - #{inv.email} (#{inv.status}, #{inv.delivery_method}) - Created: #{inv.created_at.strftime('%Y-%m-%d %H:%M')}"
    puts "     Sent: #{inv.sent_at ? 'Yes' : 'No'}, Viewed: #{inv.viewed_at ? 'Yes' : 'No'}"
  end
else
  puts "No invitations found in database yet."
end

# Step 7: Test Template Rendering
puts "\n🧪 Step 7: Testing Template Rendering..."
puts "-"*80
if email_template && user && company
  test_context = {
    'recipient_name' => 'John Test',
    'inviter_name' => user.name || user.email,
    'company_name' => company.name,
    'invitation_url' => 'https://example.com/invite?token=TEST123',
    'expires_at' => 7.days.from_now.strftime('%B %d, %Y at %I:%M %p'),
    'role' => 'Staff',
    'message' => 'Welcome to the team!'
  }
  
  begin
    rendered = email_template.render(test_context)
    has_url = rendered[:body].include?('https://example.com/invite?token=TEST123')
    has_button = rendered[:body].include?('Create Account')
    
    puts "✅ Email template renders successfully"
    puts "   Subject: #{rendered[:subject]}"
    puts "   Has URL: #{has_url}"
    puts "   Has 'Create Account' button: #{has_button}"
    
    if !has_url
      puts "   ⚠️  WARNING: invitation_url not found in rendered body!"
    end
    if !has_button
      puts "   ⚠️  WARNING: 'Create Account' button not found in rendered body!"
    end
  rescue => e
    puts "❌ Failed to render template: #{e.message}"
    puts "   #{e.backtrace.first(3).join("\n   ")}"
  end
else
  puts "⚠️  Skipping template test (missing email_template, user, or company)"
end

# Step 8: Summary and Recommendations
puts "\n" + "="*80
puts "SUMMARY & RECOMMENDATIONS"
puts "="*80

issues = []
issues << "❌ Email template not found" unless email_template
issues << "❌ SMS template not found" unless sms_template
issues << "❌ No company found" unless company
issues << "❌ No user found" unless user
issues << "⚠️  Email from_email not configured" if email_config[:from_email].blank?
issues << "⚠️  SMS from_number not configured" if sms_config[:from_number].blank?
issues << "⚠️  Twilio not configured" unless ENV['TWILIO_ACCOUNT_SID'].present?

if issues.empty?
  puts "\n✅ All systems ready! Invitation system should work correctly."
  puts "\nYou can now:"
  puts "   1. Create a user invitation via the UI"
  puts "   2. The invitation will be saved to the database"
  puts "   3. Email/SMS will be sent with the invitation URL"
  puts "   4. The URL will have a 'Create Account' button"
else
  puts "\n⚠️  Issues found:\n"
  issues.each { |issue| puts "   #{issue}" }
  
  puts "\n📝 To fix:"
  puts "   1. Templates: Already seeded above"
  puts "   2. Company: Run 'bundle exec rails c' and create: Company.create!(name: 'My Company')"
  puts "   3. User: Run 'bundle exec rails db:seed'"
  puts "   4. Email config: Set DEFAULT_EMAIL_FROM in .env"
  puts "   5. SMS config: Set TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN, TWILIO_PHONE_NUMBER in .env"
end

puts "\n" + "="*80
puts "DONE"
puts "="*80 + "\n"

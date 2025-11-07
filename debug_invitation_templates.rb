#!/usr/bin/env ruby
# Debug which invitation template is being used

require_relative 'config/environment'

puts "\n" + "="*60
puts "🔍 DEBUGGING INVITATION TEMPLATE SELECTION"
puts "="*60

# Get the company (assuming company_id = 1, adjust if needed)
company = Company.first
puts "\n📊 Company: #{company&.name || 'No company found'}"
puts "   Company ID: #{company&.id}"

# Check what templates exist
puts "\n" + "-"*60
puts "📋 ALL company_user_invitation templates in database:"
puts "-"*60

templates = CommunicationTemplate.where(template_type: 'company_user_invitation')
                                .order(company_id: :desc, created_at: :desc)

if templates.empty?
  puts "❌ NO templates found! You need to create one."
  exit 0
end

templates.each_with_index do |t, index|
  puts "\n#{index + 1}. #{t.name}"
  puts "   ID: #{t.id}"
  puts "   Channel: #{t.channel}"
  puts "   Scope: #{t.company_id ? "Company #{t.company_id}" : "🌍 Platform (all companies)"}"
  puts "   Active: #{t.is_active ? '✅' : '❌'}"
  puts "   Default: #{t.is_default ? '✅' : '❌'}"
  puts "   Created: #{t.created_at.strftime('%Y-%m-%d %H:%M')}"
  
  # Check URL type
  if t.body&.include?('http://localhost')
    puts "   URL: ❌ HTTP (needs fixing)"
  elsif t.body&.include?('https://localhost')
    puts "   URL: ✅ HTTPS"
  elsif t.body&.include?('{{ invitation_url }}')
    puts "   URL: ✅ Dynamic variable (correct)"
  else
    puts "   URL: ⚠️  No URL found"
  end
end

# Simulate what InvitationService would select
puts "\n" + "="*60
puts "🎯 TEMPLATE SELECTION SIMULATION"
puts "="*60

email_template = nil
sms_template = nil

# Try company-specific first (this is what InvitationService does)
if company
  email_template = CommunicationTemplate
                   .active
                   .for_company(company.id)
                   .by_type('company_user_invitation')
                   .for_channel('email')
                   .first
  
  sms_template = CommunicationTemplate
                 .active
                 .for_company(company.id)
                 .by_type('company_user_invitation')
                 .for_channel('sms')
                 .first
end

# Fall back to platform templates if none found
unless email_template
  email_template = CommunicationTemplate
                   .active
                   .platform
                   .by_type('company_user_invitation')
                   .for_channel('email')
                   .first
end

unless sms_template
  sms_template = CommunicationTemplate
                 .active
                 .platform
                 .by_type('company_user_invitation')
                 .for_channel('sms')
                 .first
end

puts "\n📧 EMAIL Template that will be used:"
if email_template
  puts "   ✅ #{email_template.name} (ID: #{email_template.id})"
  puts "   Scope: #{email_template.company_id ? "Company #{email_template.company_id}" : "Platform"}"
  puts "   Subject: #{email_template.subject}"
  if email_template.body&.include?('http://localhost')
    puts "   ⚠️  PROBLEM: Contains HTTP URL!"
  else
    puts "   ✅ URL looks good"
  end
else
  puts "   ❌ NO EMAIL TEMPLATE FOUND!"
end

puts "\n📱 SMS Template that will be used:"
if sms_template
  puts "   ✅ #{sms_template.name} (ID: #{sms_template.id})"
  puts "   Scope: #{sms_template.company_id ? "Company #{sms_template.company_id}" : "Platform"}"
else
  puts "   ❌ NO SMS TEMPLATE FOUND!"
end

puts "\n" + "="*60
puts "💡 RECOMMENDATIONS:"
puts "="*60

if email_template&.company_id.nil?
  puts "\n⚠️  You're using PLATFORM templates (not company-specific)"
  puts "   To use your custom template from Template Builder:"
  puts "   1. Make sure it has template_type: 'company_user_invitation'"
  puts "   2. Make sure it's associated with company_id: #{company&.id}"
  puts "   3. Make sure is_active: true"
end

if email_template&.body&.include?('http://localhost')
  puts "\n❌ Current template has HTTP URL"
  puts "   Run: ruby fix_invitation_templates_urls.rb"
end

puts "\n"

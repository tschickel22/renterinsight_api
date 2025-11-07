#!/usr/bin/env ruby
# Debug WHY company templates aren't being used

require_relative 'config/environment'

puts "\n" + "="*60
puts "🔍 DEEP DIVE: WHY ARE PLATFORM TEMPLATES BEING USED?"
puts "="*60

company = Company.first
puts "\n📊 Company: #{company.name} (ID: #{company.id})"

# Get the last invitation
last_invitation = Invitation.order(created_at: :desc).first
puts "\n📧 Last Invitation:"
if last_invitation
  puts "   Email: #{last_invitation.email}"
  puts "   Type: #{last_invitation.invitation_type}"
  puts "   Company ID: #{last_invitation.company_id || '❌ NO COMPANY!'}"
  puts "   Created: #{last_invitation.created_at}"
else
  puts "   ❌ No invitations found"
end

# Check the CommunicationTemplate model scopes
puts "\n" + "="*60
puts "🔎 CHECKING SCOPES"
puts "="*60

puts "\n1️⃣ Active company templates for company_user_invitation (email):"
active_company_templates = CommunicationTemplate
  .where(is_active: true)
  .where(company_id: company.id)
  .where(template_type: 'company_user_invitation')
  .where(channel: 'email')
  .order(created_at: :desc)

puts "   Found: #{active_company_templates.count}"
active_company_templates.each do |t|
  puts "   - #{t.name} (ID: #{t.id})"
end

puts "\n2️⃣ Active platform templates for company_user_invitation (email):"
platform_templates = CommunicationTemplate
  .where(is_active: true)
  .where(company_id: nil)
  .where(template_type: 'company_user_invitation')
  .where(channel: 'email')

puts "   Found: #{platform_templates.count}"
platform_templates.each do |t|
  puts "   - #{t.name} (ID: #{t.id})"
  if t.body.include?('http://localhost')
    puts "     ⚠️  Contains HTTP URL!"
  end
end

# Check what the actual scope methods return
puts "\n3️⃣ Using CommunicationTemplate.for_company scope:"
begin
  scoped_templates = CommunicationTemplate.for_company(company.id)
  puts "   Found: #{scoped_templates.count} templates with company_id=#{company.id}"
rescue => e
  puts "   ❌ Error: #{e.message}"
end

puts "\n4️⃣ Using CommunicationTemplate.platform scope:"
begin
  platform_scoped = CommunicationTemplate.platform
  puts "   Found: #{platform_scoped.count} platform templates"
rescue => e
  puts "   ❌ Error: #{e.message}"
end

# Now simulate exactly what InvitationService does
puts "\n" + "="*60
puts "🎯 SIMULATING InvitationService.find_template"
puts "="*60

invitation_type = 'company_user'
template_type = "#{invitation_type}_invitation"
puts "\nLooking for: template_type='#{template_type}', channel='email'"

# Try company-specific first
puts "\n1️⃣ Trying company-specific template..."
company_template = CommunicationTemplate
  .active
  .for_company(company.id)
  .by_type(template_type)
  .for_channel('email')
  .first

if company_template
  puts "   ✅ FOUND: #{company_template.name} (ID: #{company_template.id})"
  puts "   Company ID: #{company_template.company_id}"
  puts "   Is Active: #{company_template.is_active}"
  puts "   Created: #{company_template.created_at}"
  
  # Show first 200 chars of body
  puts "\n   Body preview:"
  puts "   #{company_template.body[0..200]}..."
else
  puts "   ❌ No company-specific template found"
end

# Try platform fallback
puts "\n2️⃣ Platform fallback template..."
platform_template = CommunicationTemplate
  .active
  .platform
  .by_type(template_type)
  .for_channel('email')
  .first

if platform_template
  puts "   ✅ FOUND: #{platform_template.name} (ID: #{platform_template.id})"
  puts "   Is Active: #{platform_template.is_active}"
  
  if platform_template.body.include?('http://localhost')
    puts "   ⚠️  THIS TEMPLATE HAS HTTP URL!"
  elsif platform_template.body.include?('https://localhost')
    puts "   ✅ Has HTTPS URL"
  end
end

# Final verdict
puts "\n" + "="*60
puts "🎯 VERDICT"
puts "="*60

if company_template
  puts "\n✅ InvitationService SHOULD use your custom template:"
  puts "   #{company_template.name} (ID: #{company_template.id})"
  
  if company_template.body.blank? || company_template.body.length < 50
    puts "\n⚠️  BUT YOUR TEMPLATE IS EMPTY OR TOO SHORT!"
    puts "   This might cause it to fall back to platform template"
  end
else
  puts "\n❌ InvitationService WILL use platform template:"
  puts "   #{platform_template.name} (ID: #{platform_template.id})"
  puts "\n🔧 TO FIX: Your custom template needs:"
  puts "   1. is_active = true ✅"
  puts "   2. company_id = #{company.id} ✅"
  puts "   3. template_type = 'company_user_invitation' (check this!)"
  puts "   4. channel = 'email' (check this!)"
end

# Check if there's a scope definition issue
puts "\n" + "="*60
puts "🔍 CHECKING MODEL SCOPES"
puts "="*60

puts "\nCommunicationTemplate model scopes:"
puts "   #{CommunicationTemplate.respond_to?(:active) ? '✅' : '❌'} .active"
puts "   #{CommunicationTemplate.respond_to?(:for_company) ? '✅' : '❌'} .for_company"
puts "   #{CommunicationTemplate.respond_to?(:platform) ? '✅' : '❌'} .platform"
puts "   #{CommunicationTemplate.respond_to?(:by_type) ? '✅' : '❌'} .by_type"
puts "   #{CommunicationTemplate.respond_to?(:for_channel) ? '✅' : '❌'} .for_channel"

puts "\n"

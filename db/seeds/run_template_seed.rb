# Run this file to seed all communication templates
# Usage: rails runner db/seeds/run_template_seed.rb

puts "\n🌱 Seeding ALL Communication Templates..."
puts "=" * 60

# Load company user invitation templates
puts "\n📧 Seeding Company User Invitation Templates..."
load Rails.root.join('db', 'seeds', 'communication_templates_company_user.rb')

# Load all invitation templates (portal users, tenants, etc.)
puts "\n📧 Seeding All Invitation Templates..."
load Rails.root.join('db', 'seeds', 'invitation_templates.rb')

puts "\n" + "=" * 60
puts "✨ Template seeding complete!"
puts "\n📊 Template Summary:"
puts "   Company User Invitations: #{CommunicationTemplate.where(template_type: 'company_user_invitation').count} templates"
puts "   Portal User Invitations: #{CommunicationTemplate.where(template_type: 'portal_user_invitation').count} templates"
puts "   Tenant Invitations: #{CommunicationTemplate.where(template_type: 'tenant_invitation').count} templates"
puts "\n💡 To verify templates, run:"
puts "   CommunicationTemplate.where(template_type: 'portal_user_invitation', channel: 'sms').first"

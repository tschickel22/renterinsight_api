# Run this file to seed only the communication templates
# Usage: rails runner db/seeds/run_template_seed.rb

load Rails.root.join('db', 'seeds', 'communication_templates_company_user.rb')

puts "\n✨ Template seeding complete!"
puts "To verify, check: CommunicationTemplate.where(template_type: 'company_user_invitation').count"

#!/usr/bin/env ruby
# Fix invitation template URLs from HTTP to HTTPS

require_relative 'config/environment'

puts "\n" + "="*60
puts "🔧 FIXING INVITATION TEMPLATE URLs"
puts "="*60

# Find all company_user_invitation templates
templates = CommunicationTemplate.where(template_type: 'company_user_invitation')

puts "\n📊 Found #{templates.count} invitation template(s)"

if templates.empty?
  puts "\n⚠️  No invitation templates found!"
  puts "You may need to run: rails db:seed"
  exit 0
end

templates.each do |template|
  puts "\n" + "-"*60
  puts "📝 Template: #{template.name} (ID: #{template.id})"
  puts "   Channel: #{template.channel}"
  puts "   Scope: #{template.company_id ? "Company #{template.company_id}" : "Platform"}"
  puts "   Active: #{template.is_active}"
  puts "   Default: #{template.is_default}"
  
  # Check if template contains http://localhost
  if template.body&.include?('http://localhost')
    puts "\n❌ Found HTTP URL in template body"
    
    # Replace http:// with https://
    new_body = template.body.gsub('http://localhost', 'https://localhost')
    
    # Update the template
    if template.update(body: new_body)
      puts "✅ Updated template to use HTTPS"
    else
      puts "❗ Failed to update: #{template.errors.full_messages.join(', ')}"
    end
  else
    puts "✅ Template already uses HTTPS or no localhost URL found"
  end
  
  # Show subject if it exists
  if template.subject&.present?
    puts "   Subject: #{template.subject}"
  end
end

puts "\n" + "="*60
puts "✨ Template URL fix complete!"
puts "="*60
puts "\n💡 Now restart your Rails server for changes to take effect"
puts "\n"

#!/usr/bin/env ruby
# Find ALL occurrences of http:// in the database

require_relative 'config/environment'

puts "\n" + "="*70
puts "🔍 SEARCHING FOR HTTP URLS IN DATABASE"
puts "="*70

# Check all communication templates
puts "\n📧 COMMUNICATION TEMPLATES:"
puts "-"*70

templates = CommunicationTemplate.all
templates.each do |t|
  has_http = false
  http_locations = []
  
  if t.subject&.include?('http://')
    has_http = true
    http_locations << "subject"
  end
  
  if t.body&.include?('http://')
    has_http = true
    http_locations << "body"
  end
  
  if has_http
    puts "\n❌ FOUND HTTP in template ID #{t.id}:"
    puts "   Name: #{t.name}"
    puts "   Type: #{t.template_type}"
    puts "   Channel: #{t.channel}"
    puts "   Scope: #{t.company_id ? "Company #{t.company_id}" : "Platform"}"
    puts "   Active: #{t.is_active}"
    puts "   Locations with HTTP: #{http_locations.join(', ')}"
    
    if t.body&.include?('http://')
      # Extract the HTTP URLs
      urls = t.body.scan(/http:\/\/[^\s"'<>]+/)
      puts "   HTTP URLs found:"
      urls.uniq.each do |url|
        puts "     - #{url}"
      end
    end
  end
end

# Check last few invitations
puts "\n" + "="*70
puts "📨 LAST 5 INVITATIONS:"
puts "-"*70

invitations = Invitation.order(created_at: :desc).limit(5)
invitations.each_with_index do |inv, i|
  puts "\n#{i+1}. Invitation ID: #{inv.id}"
  puts "   Email: #{inv.email}"
  puts "   Created: #{inv.created_at}"
  puts "   Company: #{inv.company&.name || 'None'}"
  puts "   Type: #{inv.invitation_type}"
end

# Check communications sent
puts "\n" + "="*70
puts "📬 LAST 5 SENT COMMUNICATIONS (Actual Emails/SMS):"
puts "-"*70

communications = Communication.order(created_at: :desc).limit(5)
communications.each_with_index do |comm, i|
  puts "\n#{i+1}. Communication ID: #{comm.id}"
  puts "   Channel: #{comm.channel}"
  puts "   To: #{comm.to}"
  puts "   Subject: #{comm.subject}" if comm.subject
  puts "   Created: #{comm.created_at}"
  
  # Check if body contains HTTP
  if comm.body&.include?('http://')
    puts "   ⚠️  BODY CONTAINS HTTP URL!"
    urls = comm.body.scan(/http:\/\/[^\s"'<>]+/)
    urls.uniq.each do |url|
      puts "      - #{url}"
    end
  elsif comm.body&.include?('https://')
    puts "   ✅ Body contains HTTPS URL"
  else
    puts "   ⚠️  No URL found in body"
  end
  
  # Show first 200 chars of body
  if comm.body
    puts "   Body preview: #{comm.body[0..150]}..."
  end
end

# Check environment variable
puts "\n" + "="*70
puts "🔧 ENVIRONMENT VARIABLES:"
puts "-"*70
puts "FRONTEND_URL = #{ENV['FRONTEND_URL'] || 'NOT SET'}"
puts "PORTAL_URL = #{ENV['PORTAL_URL'] || 'NOT SET'}"

# Check what URL the InvitationService would generate
puts "\n" + "="*70
puts "🎯 WHAT URL WOULD BE GENERATED NOW?"
puts "-"*70

test_url = ENV['FRONTEND_URL'] || 'https://localhost:5173'
test_path = '/invitations/accept'
test_token = 'TEST_TOKEN_123'
full_url = "#{test_url}#{test_path}?token=#{test_token}"

puts "Generated URL: #{full_url}"

if full_url.start_with?('http://')
  puts "❌ PROBLEM: URL is HTTP!"
  puts "   ENV['FRONTEND_URL'] = #{ENV['FRONTEND_URL']}"
elsif full_url.start_with?('https://')
  puts "✅ URL is HTTPS (correct)"
else
  puts "⚠️  Unknown protocol"
end

puts "\n" + "="*70
puts "💡 DIAGNOSIS COMPLETE"
puts "="*70
puts "\n"

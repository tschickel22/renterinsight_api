#!/usr/bin/env rails runner

require 'ostruct'

puts "=" * 50
puts "Testing Form Submission API"
puts "=" * 50

# Find a form to test with
form = IntakeForm.active.last
unless form
  puts "No active forms found. Creating one..."
  form = IntakeForm.create!(
    company: Company.first,
    source: Source.first,
    name: "Test API Form",
    is_active: true,
    schema: [
      { "id" => "1", "name" => "firstName", "label" => "First Name", "type" => "text" },
      { "id" => "2", "name" => "email", "label" => "Email", "type" => "email" }
    ]
  )
end

puts "Using form: #{form.name}"
puts "Public ID: #{form.public_id}"
puts "Form URL: http://localhost:5173/f/#{form.public_id}"

# Test 1: Direct model submission (should work based on our earlier test)
puts "\n--- Test 1: Direct Model Creation ---"
leads_before = Lead.count
submission = form.intake_submissions.create!(
  data: {
    "firstName" => "Direct Test",
    "email" => "direct@test.com"
  }
)
leads_after = Lead.count

if leads_after > leads_before
  puts "✅ Direct submission created lead successfully"
else
  puts "❌ Direct submission did NOT create lead"
end

# Test 2: Check the public API route
puts "\n--- Test 2: Route Check ---"

# List all routes that match our public form endpoints
Rails.application.routes.routes.each do |route|
  if route.path.spec.to_s.include?('/f/:public_id')
    puts "Found route: #{route.verb.ljust(6)} #{route.path.spec}"
  end
end

puts "\n" + "=" * 50
puts "Debugging Info"
puts "=" * 50

# Check recent submissions
recent = IntakeSubmission.order(created_at: :desc).limit(5)
puts "\nRecent submissions:"
recent.each do |sub|
  data_preview = sub.data ? sub.data.to_json[0..50] : "nil"
  puts "  ID: #{sub.id}, Form: #{sub.intake_form.name}, Lead: #{sub.lead_id || 'none'}, Data: #{data_preview}..."
end

# Check recent leads  
recent_leads = Lead.order(created_at: :desc).limit(3)
puts "\nRecent leads:"
recent_leads.each do |lead|
  puts "  ID: #{lead.id}, Name: #{lead.first_name} #{lead.last_name}, Email: #{lead.email}, Created: #{lead.created_at}"
end

# Check for Jose Garcia specifically
jose = Lead.where("first_name LIKE ? OR last_name LIKE ?", "%jose%", "%garcia%").last
if jose
  puts "\nFound Jose Garcia lead:"
  puts "  ID: #{jose.id}, Name: #{jose.first_name} #{jose.last_name}, Created: #{jose.created_at}"
else
  puts "\nNo lead found with name containing 'jose' or 'garcia'"
end

puts "\n" + "=" * 50
puts "Test Complete"
puts "=" * 50

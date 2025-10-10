#!/usr/bin/env rails runner

puts "=" * 50
puts "Testing Lead Creation from Intake Forms"
puts "=" * 50

# Get or create a company and source
company = Company.first || Company.create!(name: "Test Company")
source = Source.first || Source.create!(name: "Web Form", source_type: "Online")

puts "Using company: #{company.name}"
puts "Using source: #{source.name}"

# Create a test form
form = IntakeForm.create!(
  company: company,
  source: source,
  name: "Contact Form",
  description: "Test form for lead generation",
  is_active: true,
  schema: [
    { "id" => "1", "name" => "firstName", "label" => "First Name", "type" => "text", "required" => true },
    { "id" => "2", "name" => "lastName", "label" => "Last Name", "type" => "text", "required" => false },
    { "id" => "3", "name" => "email", "label" => "Email", "type" => "email", "required" => true },
    { "id" => "4", "name" => "phone", "label" => "Phone", "type" => "phone", "required" => false },
    { "id" => "5", "name" => "budget", "label" => "Budget", "type" => "select", "options" => ["Under $50k", "$50k-$100k", "Over $100k"] }
  ]
)

puts "\n✓ Created form: #{form.name} (ID: #{form.id})"

# Count leads before
leads_before = Lead.count
puts "\nLeads before submission: #{leads_before}"

# Create a submission
submission_data = {
  "firstName" => "John",
  "lastName" => "Doe",
  "email" => "john.doe@example.com",
  "phone" => "555-1234",
  "budget" => "$50k-$100k"
}

puts "\nCreating submission with data:"
submission_data.each { |k,v| puts "  #{k}: #{v}" }

submission = form.intake_submissions.create!(
  data: submission_data,
  ip_address: "127.0.0.1",
  user_agent: "Test Script",
  submitted_at: Time.current
)

puts "\n✓ Created submission ID: #{submission.id}"

# Check if lead was created
leads_after = Lead.count
puts "\nLeads after submission: #{leads_after}"

if leads_after > leads_before
  lead = Lead.last
  puts "\n✅ SUCCESS: Lead was created!"
  puts "\nLead details:"
  puts "  ID: #{lead.id}"
  puts "  Name: #{lead.first_name} #{lead.last_name}"
  puts "  Email: #{lead.email}"
  puts "  Phone: #{lead.phone}"
  puts "  Source: #{lead.source&.name}"
  puts "  Company: #{lead.company&.name}"
  puts "  Status: #{lead.status}"
  puts "\nNotes:"
  puts lead.notes.to_s.split("\n").map { |line| "  #{line}" }.join("\n")
else
  puts "\n❌ ERROR: Lead was not created"
  
  # Check the submission status
  submission.reload
  puts "\nSubmission details:"
  puts "  Lead created flag: #{submission.lead_created}"
  puts "  Lead ID: #{submission.lead_id}"
  
  # Check logs for errors
  puts "\nCheck Rails logs for errors: tail -f log/development.log"
end

puts "\n" + "=" * 50
puts "Test Complete"
puts "=" * 50

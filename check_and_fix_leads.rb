#!/usr/bin/env rails runner

puts "Checking leads table schema..."

# Check if company_id exists on leads table
columns = ActiveRecord::Base.connection.columns('leads').map(&:name)
puts "Current leads columns:"
columns.each { |col| puts "  - #{col}" }

if !columns.include?('company_id')
  puts "\n Missing company_id column on leads table"
  puts "Adding company_id column..."
  
  ActiveRecord::Base.connection.add_column :leads, :company_id, :bigint
  
  # Add foreign key if companies table exists
  if ActiveRecord::Base.connection.table_exists?('companies')
    begin
      ActiveRecord::Base.connection.add_foreign_key :leads, :companies
      ActiveRecord::Base.connection.add_index :leads, :company_id
    rescue => e
      puts "Note: #{e.message}"
    end
  end
  
  # Set default company for existing leads
  if Company.any?
    default_company = Company.first
    Lead.update_all(company_id: default_company.id)
    puts "Added company_id column and set default to #{default_company.name}"
  else
    puts "Added company_id column"
  end
else
  puts "company_id column already exists"
end

puts "\n" + "=" * 50
puts "Testing lead creation from form submission..."
puts "=" * 50

# Create test data
company = Company.first || Company.create!(name: "Test Company")
source = Source.first || Source.create!(name: "Web Form", source_type: "Online")

puts "Using company: #{company.name} (ID: #{company.id})"
puts "Using source: #{source.name} (ID: #{source.id})"

# Find or create a test form
form = IntakeForm.where(company_id: company.id).last || IntakeForm.create!(
  company: company,
  source: source,
  name: "Lead Capture Form #{Time.now.to_i}",
  is_active: true,
  schema: [
    { "id" => "1", "name" => "firstName", "label" => "First Name", "type" => "text" },
    { "id" => "2", "name" => "lastName", "label" => "Last Name", "type" => "text" },
    { "id" => "3", "name" => "email", "label" => "Email", "type" => "email" },
    { "id" => "4", "name" => "phone", "label" => "Phone", "type" => "phone" }
  ]
)

puts "\nUsing form: #{form.name} (ID: #{form.id})"

# Count leads before
leads_before = Lead.count
puts "\nLeads count before: #{leads_before}"

# Create a test submission
test_data = {
  "firstName" => "John",
  "lastName" => "Smith",
  "email" => "john.smith.#{Time.now.to_i}@example.com",
  "phone" => "555-#{rand(1000..9999)}"
}

puts "\nCreating submission with:"
test_data.each { |k, v| puts "  #{k}: #{v}" }

submission = form.intake_submissions.build(
  data: test_data,
  ip_address: "127.0.0.1",
  user_agent: "Test Script"
)

# Save and let the callback create the lead
if submission.save
  puts "Submission created (ID: #{submission.id})"
  
  # Wait a moment for callbacks to complete
  sleep(0.5)
  submission.reload
  
  leads_after = Lead.count
  puts "\nLeads count after: #{leads_after}"
  
  if leads_after > leads_before
    lead = Lead.find(submission.lead_id) rescue Lead.last
    puts "\n SUCCESS: Lead was created!"
    puts "\nLead details:"
    puts "  ID: #{lead.id}"
    puts "  Company: #{lead.company.name}"
    puts "  Name: #{lead.first_name} #{lead.last_name}"
    puts "  Email: #{lead.email}"
    puts "  Phone: #{lead.phone}"
    puts "  Source: #{lead.source&.name}"
    
    if lead.notes.present?
      puts "\nNotes preview:"
      lead.notes.to_s.split("\n").first(5).each { |line| puts "  #{line}" }
    end
  else
    puts "\n Lead was NOT created"
    puts "Submission status:"
    puts "  lead_created: #{submission.lead_created}"
    puts "  lead_id: #{submission.lead_id}"
    
    # Try manual creation
    puts "\nAttempting manual lead creation..."
    result = submission.create_lead_from_submission
    if result
      puts "Manual creation succeeded!"
      puts "Lead ID: #{result.id}"
    else
      puts "Manual creation also failed"
    end
  end
else
  puts "Failed to save submission: #{submission.errors.full_messages.join(', ')}"
end

puts "\n" + "=" * 50
puts "Test complete!"
puts "=" * 50

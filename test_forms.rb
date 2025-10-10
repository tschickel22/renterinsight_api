#!/usr/bin/env rails console

# Test intake form fields persistence

puts "=" * 50
puts "Testing Intake Form Fields Storage"
puts "=" * 50

# Get or create a company
company = Company.first || Company.create!(name: "Test Company")
puts "Using company: #{company.name} (ID: #{company.id})"

# Create a form with fields
form_fields = [
  { 
    "id" => "field_1",
    "name" => "firstName",
    "label" => "First Name",
    "type" => "text",
    "required" => true,
    "placeholder" => "Enter your first name",
    "order" => 1,
    "isActive" => true
  },
  {
    "id" => "field_2", 
    "name" => "email",
    "label" => "Email Address",
    "type" => "email",
    "required" => true,
    "placeholder" => "your@email.com",
    "order" => 2,
    "isActive" => true
  },
  {
    "id" => "field_3",
    "name" => "budget",
    "label" => "Budget Range",
    "type" => "select",
    "required" => false,
    "options" => ["Under $50k", "$50k-$100k", "Over $100k"],
    "order" => 3,
    "isActive" => true
  }
]

puts "\nCreating form with #{form_fields.length} fields..."

form = IntakeForm.create!(
  company: company,
  name: "Contact Form Test #{Time.now.strftime('%H:%M:%S')}",
  description: "Testing field persistence",
  is_active: true,
  schema: form_fields  # Using schema column directly
)

puts "✓ Form created with ID: #{form.id}"
puts "  Public ID: #{form.public_id}"

# Retrieve the form
puts "\nRetrieving form..."
retrieved_form = IntakeForm.find(form.id)

puts "✓ Form retrieved"
puts "  Fields count: #{retrieved_form.fields.length}"

if retrieved_form.fields.any?
  puts "\nField details:"
  retrieved_form.fields.each do |field|
    puts "  - #{field['label']} (#{field['name']}): type=#{field['type']}, required=#{field['required']}"
  end
  puts "\n✅ SUCCESS: Fields are persisting correctly!"
else
  puts "\n❌ ERROR: Fields not found after retrieval"
end

# Test JSON response
puts "\nTesting as_json output:"
json = retrieved_form.as_json
puts "  Has 'fields' key: #{json.key?('fields') ? '✓' : '✗'}"
puts "  Has 'isActive' key: #{json.key?('isActive') ? '✓' : '✗'}"
puts "  Has 'publicId' key: #{json.key?('publicId') ? '✓' : '✗'}"
puts "  Fields in JSON: #{json['fields'].length}"

puts "\nPublic URL: #{json['publicUrl']}"
puts "Share this URL: http://localhost:5173/f/#{json['publicId']}"

puts "\n" + "=" * 50
puts "Test Complete"
puts "=" * 50

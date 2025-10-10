#!/usr/bin/env rails runner

puts "Checking database schema for intake_forms..."

# Check what columns exist
if ActiveRecord::Base.connection.table_exists?('intake_forms')
  columns = ActiveRecord::Base.connection.columns('intake_forms').map(&:name)
  puts "Current columns: #{columns.join(', ')}"
  
  # Check for missing columns
  missing = []
  missing << 'source_id' unless columns.include?('source_id')
  missing << 'fields' unless columns.include?('fields')
  
  if missing.any?
    puts "Missing columns: #{missing.join(', ')}"
    
    # Add source_id if missing
    if !columns.include?('source_id')
      puts "Adding source_id column..."
      ActiveRecord::Base.connection.add_column :intake_forms, :source_id, :bigint
      begin
        ActiveRecord::Base.connection.add_foreign_key :intake_forms, :sources
        ActiveRecord::Base.connection.add_index :intake_forms, :source_id
      rescue => e
        puts "Note: #{e.message}"
      end
      puts "✓ Added source_id"
    end
  else
    puts "✓ All expected columns present"
  end
  
  # Test creating a form with fields
  puts "\nTesting form creation with fields..."
  company = Company.first || Company.create!(name: "Test Company")
  
  test_form = IntakeForm.new(
    company: company,
    name: "Test Form #{Time.now.to_i}",
    description: "Testing fields storage",
    is_active: true
  )
  
  # Set fields using the schema column
  test_form.schema = [
    { id: "1", name: "firstName", label: "First Name", type: "text", required: true, order: 1 },
    { id: "2", name: "email", label: "Email", type: "email", required: true, order: 2 }
  ]
  
  if test_form.save
    puts "✓ Form created successfully"
    puts "  - ID: #{test_form.id}"
    puts "  - Public ID: #{test_form.public_id}"
    puts "  - Fields stored: #{test_form.fields.inspect}"
    
    # Test retrieval
    retrieved = IntakeForm.find(test_form.id)
    puts "  - Fields retrieved: #{retrieved.fields.inspect}"
    
    if retrieved.fields.any?
      puts "✓ Fields persist correctly!"
    else
      puts "✗ Fields not persisting"
    end
  else
    puts "✗ Failed to create form: #{test_form.errors.full_messages.join(', ')}"
  end
  
  # Check intake_submissions columns
  puts "\nChecking intake_submissions table..."
  if ActiveRecord::Base.connection.table_exists?('intake_submissions')
    sub_columns = ActiveRecord::Base.connection.columns('intake_submissions').map(&:name)
    puts "Columns: #{sub_columns.join(', ')}"
    
    if !sub_columns.include?('lead_id')
      puts "Adding lead_id column to intake_submissions..."
      ActiveRecord::Base.connection.add_column :intake_submissions, :lead_id, :bigint
      begin
        ActiveRecord::Base.connection.add_foreign_key :intake_submissions, :leads
      rescue => e
        puts "Note: #{e.message}"
      end
      puts "✓ Added lead_id"
    end
  end
  
else
  puts "✗ intake_forms table does not exist!"
end

puts "\nDone!"

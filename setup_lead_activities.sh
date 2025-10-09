#!/bin/bash
# Setup script for Lead Activities feature

echo "========================================="
echo "Lead Activities Setup Script"
echo "========================================="
echo ""

# Navigate to the Rails app directory
cd "$(dirname "$0")"

echo "1. Checking database connection..."
bundle exec rails runner "puts 'Database connected: ' + ActiveRecord::Base.connection.active?.to_s"
echo ""

echo "2. Running migration..."
bundle exec rails db:migrate
echo ""

echo "3. Checking if lead_activities table exists..."
bundle exec rails runner "
if ActiveRecord::Base.connection.table_exists?('lead_activities')
  puts '✓ lead_activities table exists'
  puts 'Columns:'
  ActiveRecord::Base.connection.columns('lead_activities').each do |col|
    puts \"  - #{col.name} (#{col.type})\"
  end
else
  puts '✗ lead_activities table does NOT exist'
  puts 'Please check migration errors above'
end
"
echo ""

echo "4. Checking LeadActivity model..."
bundle exec rails runner "
begin
  puts 'LeadActivity class: ' + LeadActivity.name
  puts 'Table name: ' + LeadActivity.table_name
  puts 'Column names: ' + LeadActivity.column_names.join(', ')
  puts '✓ LeadActivity model loaded successfully'
rescue => e
  puts '✗ Error loading LeadActivity model:'
  puts e.message
  puts e.backtrace.first(5).join(\"\n\")
end
"
echo ""

echo "5. Testing basic CRUD operations..."
bundle exec rails runner "
begin
  # Get first lead and user
  lead = Lead.first
  user = User.first
  
  unless lead && user
    puts '✗ Need at least one lead and one user in database'
    exit 1
  end
  
  puts \"Using Lead ##{lead.id}: #{lead.first_name} #{lead.last_name}\"
  puts \"Using User ##{user.id}: #{user.name}\"
  puts ''
  
  # Test creating an activity
  activity = LeadActivity.create!(
    lead: lead,
    user: user,
    assigned_to: user,
    activity_type: 'task',
    subject: 'Test Task',
    description: 'This is a test task',
    priority: 'medium',
    status: 'pending',
    due_date: 3.days.from_now
  )
  
  puts \"✓ Created activity ##{activity.id}: #{activity.subject}\"
  
  # Test reading
  found = LeadActivity.find(activity.id)
  puts \"✓ Found activity: #{found.subject}\"
  
  # Test updating
  activity.update!(subject: 'Updated Test Task')
  puts '✓ Updated activity'
  
  # Test completing
  activity.complete!
  puts '✓ Completed activity'
  
  # Test deleting
  activity.destroy!
  puts '✓ Deleted activity'
  
  puts ''
  puts '✓✓✓ All CRUD operations successful!'
  
rescue => e
  puts '✗ Error during CRUD test:'
  puts e.message
  puts e.backtrace.first(10).join(\"\n\")
  exit 1
end
"
echo ""

echo "========================================="
echo "Setup complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Restart your Rails server"
echo "2. Refresh your browser"
echo "3. Navigate to a lead and click the Activities tab"

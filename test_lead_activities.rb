# Test script for Lead Activities
# Run with: bundle exec rails runner test_lead_activities.rb

puts "Testing Lead Activities Feature"
puts "=" * 50

# Check if table exists
unless ActiveRecord::Base.connection.table_exists?('lead_activities')
  puts "ERROR: lead_activities table does not exist!"
  puts "Please run: bundle exec rails db:migrate"
  exit 1
end

puts "✓ lead_activities table exists"

# Get test data
lead = Lead.first
user = User.first

unless lead && user
  puts "ERROR: Need at least one lead and user in database"
  exit 1
end

puts "Using Lead ##{lead.id}: #{lead.first_name} #{lead.last_name}"
puts "Using User ##{user.id}: #{user.name}"
puts ""

# Test 1: Create a task
puts "Test 1: Creating a task..."
begin
  task = LeadActivity.create!(
    lead: lead,
    user: user,
    assigned_to: user,
    activity_type: 'task',
    subject: 'Test Task',
    description: 'This is a test task',
    priority: 'high',
    status: 'pending',
    due_date: 3.days.from_now,
    estimated_hours: 2
  )
  puts "✓ Created task ##{task.id}"
rescue => e
  puts "✗ Failed to create task:"
  puts "  #{e.message}"
  puts "  #{e.backtrace.first(3).join("\n  ")}"
end

# Test 2: Create a meeting
puts "\nTest 2: Creating a meeting..."
begin
  meeting = LeadActivity.create!(
    lead: lead,
    user: user,
    assigned_to: user,
    activity_type: 'meeting',
    subject: 'Client Meeting',
    description: 'Discuss requirements',
    priority: 'high',
    status: 'pending',
    start_time: 2.days.from_now.change(hour: 14),
    end_time: 2.days.from_now.change(hour: 15),
    meeting_location: 'Conference Room A',
    meeting_link: 'https://zoom.us/j/123456'
  )
  puts "✓ Created meeting ##{meeting.id}"
rescue => e
  puts "✗ Failed to create meeting:"
  puts "  #{e.message}"
  puts "  #{e.backtrace.first(3).join("\n  ")}"
end

# Test 3: Create a call
puts "\nTest 3: Creating a call..."
begin
  call = LeadActivity.create!(
    lead: lead,
    user: user,
    assigned_to: user,
    activity_type: 'call',
    subject: 'Follow-up Call',
    description: 'Discuss proposal',
    priority: 'medium',
    status: 'pending',
    due_date: 1.day.from_now,
    phone_number: '+1-555-0123',
    call_direction: 'outbound'
  )
  puts "✓ Created call ##{call.id}"
rescue => e
  puts "✗ Failed to create call:"
  puts "  #{e.message}"
  puts "  #{e.backtrace.first(3).join("\n  ")}"
end

# Test 4: Create a reminder
puts "\nTest 4: Creating a reminder..."
begin
  reminder = LeadActivity.create!(
    lead: lead,
    user: user,
    assigned_to: user,
    activity_type: 'reminder',
    subject: 'Send Proposal',
    description: 'Remember to send the proposal document',
    priority: 'urgent',
    status: 'pending',
    reminder_time: 1.day.from_now,
    reminder_method: ['email', 'popup']
  )
  puts "✓ Created reminder ##{reminder.id}"
  puts "  Reminder methods: #{reminder.reminder_method.inspect}"
rescue => e
  puts "✗ Failed to create reminder:"
  puts "  #{e.message}"
  puts "  #{e.backtrace.first(3).join("\n  ")}"
end

# Test 5: List all activities
puts "\nTest 5: Listing all activities for lead..."
activities = lead.lead_activities
puts "✓ Found #{activities.count} activities"
activities.each do |activity|
  puts "  - #{activity.activity_type}: #{activity.subject} (#{activity.status})"
end

# Test 6: Complete an activity
if LeadActivity.first
  puts "\nTest 6: Completing an activity..."
  begin
    activity = LeadActivity.first
    activity.complete!
    puts "✓ Completed activity ##{activity.id}"
  rescue => e
    puts "✗ Failed to complete activity:"
    puts "  #{e.message}"
  end
end

# Test 7: Delete activities
puts "\nTest 7: Cleaning up test activities..."
LeadActivity.where(subject: ['Test Task', 'Client Meeting', 'Follow-up Call', 'Send Proposal']).destroy_all
puts "✓ Cleanup complete"

puts "\n" + "=" * 50
puts "All tests completed!"

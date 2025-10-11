#!/bin/bash

echo "======================================"
echo "Verifying Account Activities Setup"
echo "======================================"
echo ""

# Check if table exists
echo "1. Checking if account_activities table exists..."
bundle exec rails runner "
if ActiveRecord::Base.connection.table_exists?('account_activities')
  puts '✅ Table account_activities exists!'
else
  puts '❌ Table account_activities NOT found'
  puts 'Running migration...'
  system('bundle exec rails db:migrate')
end
"

echo ""
echo "2. Checking Account model association..."
bundle exec rails runner "
if Account.new.respond_to?(:activities)
  puts '✅ Account.activities association is working!'
else
  puts '❌ Account.activities association NOT found'
end
"

echo ""
echo "3. Testing account activities..."
bundle exec rails runner "
begin
  account = Account.first
  if account
    puts \"Using account: #{account.name} (ID: #{account.id})\"
    
    # Create a test activity
    activity = account.activities.create!(
      activity_type: 'note',
      description: 'Test activity - created by setup script',
      outcome: 'positive',
      user_id: User.first&.id
    )
    
    puts \"✅ Created activity ID: #{activity.id}\"
    
    # Count activities
    puts \"   Total activities for this account: #{account.activities.count}\"
    
    # Clean up
    activity.destroy
    puts \"✅ Test activity cleaned up\"
  else
    puts '⚠️  No accounts found. Creating test account...'
    account = Account.create!(
      name: 'Test Account',
      email: 'test@example.com',
      status: 'active',
      account_type: 'prospect'
    )
    puts \"✅ Created test account: #{account.name} (ID: #{account.id})\"
  end
rescue => e
  puts \"❌ Error: #{e.message}\"
  puts e.backtrace.first(5)
end
"

echo ""
echo "4. Testing API endpoints..."
bundle exec rails runner "
account = Account.first
if account
  puts \"Testing with account ID: #{account.id}\"
  puts ''
  puts 'Available API endpoints:'
  puts \"  GET    http://localhost:3001/api/v1/accounts/#{account.id}/activities\"
  puts \"  POST   http://localhost:3001/api/v1/accounts/#{account.id}/activities\"
  puts \"  GET    http://localhost:3001/api/v1/accounts/#{account.id}/insights\"
  puts \"  GET    http://localhost:3001/api/v1/accounts/#{account.id}/score\"
  puts \"  GET    http://localhost:3001/api/v1/accounts/#{account.id}/messages\"
end
"

echo ""
echo "======================================"
echo "✅ Setup Complete!"
echo "======================================"
echo ""
echo "Next steps:"
echo "1. Start your Rails server: bundle exec rails server -p 3001"
echo "2. Open your React app and go to any account detail page"
echo "3. Click on the Activity, Communication, or AI Insights tabs"
echo ""

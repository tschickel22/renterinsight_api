#!/bin/bash
# COPY AND PASTE THESE COMMANDS INTO YOUR WSL TERMINAL

# 1. Navigate to the Rails app
cd /home/tschi/src/renterinsight_api

# 2. Check current migration status
echo "Current database version:"
bundle exec rails db:version

# 3. Run the migration
echo ""
echo "Running migration..."
bundle exec rails db:migrate

# 4. Verify the migration worked
echo ""
echo "Checking if lead_activities table exists..."
bundle exec rails runner "
if ActiveRecord::Base.connection.table_exists?('lead_activities')
  puts '✓✓✓ SUCCESS! Table exists!'
  puts 'Number of columns: ' + ActiveRecord::Base.connection.columns('lead_activities').count.to_s
else
  puts '✗✗✗ FAILED! Table does not exist'
  puts 'Please check for errors above'
end
"

# 5. Show final status
echo ""
echo "New database version:"
bundle exec rails db:version

echo ""
echo "========================================="
echo "If you see 'SUCCESS' above, you're done!"
echo "Now RESTART your Rails server and refresh your browser"
echo "========================================="

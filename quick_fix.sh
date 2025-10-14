#!/bin/bash
# Quick fix script for Lead Activities

echo "Lead Activities Quick Fix"
echo "========================="
echo ""

cd "$(dirname "$0")"

# 1. Ensure we have at least one user
echo "1. Checking for users..."
USER_COUNT=$(bundle exec rails runner "puts User.count")
if [ "$USER_COUNT" -eq "0" ]; then
    echo "   Creating default user..."
    bundle exec rails runner "User.create!(name: 'System User', email: 'system@example.com')"
    echo "   ✓ User created"
else
    echo "   ✓ Found $USER_COUNT user(s)"
fi
echo ""

# 2. Run migration if needed
echo "2. Checking database..."
TABLE_EXISTS=$(bundle exec rails runner "puts ActiveRecord::Base.connection.table_exists?('lead_activities')")
if [ "$TABLE_EXISTS" = "false" ]; then
    echo "   Running migration..."
    bundle exec rails db:migrate
    echo "   ✓ Migration complete"
else
    echo "   ✓ Table exists"
fi
echo ""

# 3. Verify model loads
echo "3. Checking model..."
bundle exec rails runner "
begin
  LeadActivity
  puts '   ✓ Model loads successfully'
rescue => e
  puts '   ✗ Model error: ' + e.message
  exit 1
end
"
echo ""

echo "========================="
echo "Setup complete!"
echo ""
echo "Next steps:"
echo "1. Restart Rails server"
echo "2. Refresh browser"
echo "3. Try creating an activity"

#!/bin/bash
cd ~/src/renterinsight_api

echo "=========================================="
echo "🔍 Finding Working Credentials"
echo "=========================================="
echo ""

# Get users with more details
echo "1️⃣  Users in database:"
echo "---------------------"
bundle exec rails runner "
User.limit(10).each do |u|
  puts \"  #{u.email.ljust(35)} | ID: #{u.id} | Has password: #{u.encrypted_password.present?}\"
end
"
echo ""

# Try to create a test user if needed
echo "2️⃣  Creating/Finding test user..."
echo "---------------------------------"
bundle exec rails runner "
# Try to find or create a test user
test_user = User.find_or_initialize_by(email: 'mfa-test@example.com')

if test_user.new_record?
  test_user.assign_attributes(
    name: 'MFA Test User',
    password: 'password123',
    password_confirmation: 'password123'
  )
  
  if test_user.save
    puts '✅ Created test user: mfa-test@example.com'
    puts '   Password: password123'
  else
    puts '❌ Failed to create test user:'
    puts test_user.errors.full_messages.join(', ')
  end
else
  # Update password for existing user
  test_user.password = 'password123'
  test_user.password_confirmation = 'password123'
  
  if test_user.save
    puts '✅ Updated test user: mfa-test@example.com'
    puts '   Password: password123'
  else
    puts '❌ Failed to update test user:'
    puts test_user.errors.full_messages.join(', ')
  end
end
"
echo ""

# Now test auth with the test user
echo "3️⃣  Testing authentication..."
echo "-----------------------------"
AUTH_RESPONSE=$(curl -s -k -X POST https://localhost:3001/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"mfa-test@example.com","password":"password123"}')

TOKEN=$(echo "$AUTH_RESPONSE" | jq -r '.token // .access_token // .jwt // empty')

if [ -n "$TOKEN" ] && [ "$TOKEN" != "null" ]; then
    echo "✅ Authentication successful!"
    echo "   Email: mfa-test@example.com"
    echo "   Password: password123"
    echo "   Token: ${TOKEN:0:30}..."
    echo ""
    echo "=========================================="
    echo "✅ Ready to run full API tests!"
    echo "=========================================="
else
    echo "❌ Auth still failed. Response:"
    echo "$AUTH_RESPONSE" | jq '.'
fi

# frozen_string_literal: true

# Phase 5A: Authentication Test Users
# Run with: bin/rails db:seed

puts "🔐 Creating Phase 5A Test Users..."

# Clear existing test users
User.where(email: ['admin@test.com', 'sarah.johnson@example.com', 'admin@renterinsight.com', 'client@test.com']).destroy_all

# Admin User 1
admin1 = User.create!(
  email: 'admin@test.com',
  password: 'password123',
  password_confirmation: 'password123',
  first_name: 'Admin',
  last_name: 'User',
  role: 'admin',
  status: 'active'
)
puts "✅ Created: #{admin1.email} (#{admin1.role})"

# Admin User 2
admin2 = User.create!(
  email: 'admin@renterinsight.com',
  password: 'password123',
  password_confirmation: 'password123',
  first_name: 'System',
  last_name: 'Admin',
  role: 'admin',
  status: 'active'
)
puts "✅ Created: #{admin2.email} (#{admin2.role})"

# Client User 1
client1 = User.create!(
  email: 'sarah.johnson@example.com',
  password: 'password123',
  password_confirmation: 'password123',
  first_name: 'Sarah',
  last_name: 'Johnson',
  role: 'client',
  status: 'active'
)
puts "✅ Created: #{client1.email} (#{client1.role})"

# Client User 2
client2 = User.create!(
  email: 'client@test.com',
  password: 'password123',
  password_confirmation: 'password123',
  first_name: 'Test',
  last_name: 'Client',
  role: 'client',
  status: 'active'
)
puts "✅ Created: #{client2.email} (#{client2.role})"

# Staff User
staff = User.create!(
  email: 'staff@test.com',
  password: 'password123',
  password_confirmation: 'password123',
  first_name: 'Staff',
  last_name: 'Member',
  role: 'staff',
  status: 'active'
)
puts "✅ Created: #{staff.email} (#{staff.role})"

puts "\n🎉 Phase 5A Test Users Created!\n\n"
puts "=" * 60
puts "TEST CREDENTIALS"
puts "=" * 60
puts "\n📧 Admin Login:"
puts "   Email: admin@test.com"
puts "   Password: password123"
puts "   Dashboard: /admin/dashboard\n"
puts "\n📧 Client Login:"
puts "   Email: sarah.johnson@example.com"
puts "   Password: password123"
puts "   Dashboard: /client/dashboard\n"
puts "\n📧 Staff Login:"
puts "   Email: staff@test.com"
puts "   Password: password123"
puts "   Dashboard: /staff/dashboard\n"
puts "=" * 60

# Verify passwords work
puts "\n🔍 Verifying password authentication..."
test_user = User.find_by(email: 'admin@test.com')
if test_user.authenticate('password123')
  puts "✅ Password authentication working correctly!"
else
  puts "❌ Password authentication failed!"
end

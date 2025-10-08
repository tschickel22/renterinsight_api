# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

Company.find_or_create_by!(name:'Demo Company')

# Create default user for activities and reminders
User.find_or_create_by!(email: 'system@example.com') do |user|
  user.name = 'System User'
end

puts "Seeded: #{Company.count} companies, #{User.count} users"

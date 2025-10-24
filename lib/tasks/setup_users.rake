# frozen_string_literal: true

namespace :app do
  desc "Create production admin and client users"
  task setup_users: :environment do
    puts "🔧 Setting up production users..."
    
    # Create or update admin user
    admin = User.find_or_initialize_by(email: 't+admin@renterinsight.com')
    admin.assign_attributes(
      first_name: 'Tom',
      last_name: 'Admin',
      role: 'admin',
      status: 'active',
      password: 'Mindzenty1!',
      password_confirmation: 'Mindzenty1!'
    )
    
    if admin.save
      puts "✅ Admin user created/updated successfully!"
      puts "   Email: #{admin.email}"
      puts "   Role: #{admin.role}"
    else
      puts "❌ Failed to create admin: #{admin.errors.full_messages.join(', ')}"
    end
    
    # Create or update client user
    client = User.find_or_initialize_by(email: 't+client@renterinsight.com')
    client.assign_attributes(
      first_name: 'Tom',
      last_name: 'Client',
      role: 'client',
      status: 'active',
      password: 'password123',
      password_confirmation: 'password123'
    )
    
    if client.save
      puts "✅ Client user created/updated successfully!"
      puts "   Email: #{client.email}"
      puts "   Role: #{client.role}"
    else
      puts "❌ Failed to create client: #{client.errors.full_messages.join(', ')}"
    end
    
    puts "🎉 User setup complete!"
  end
end

# frozen_string_literal: true

module Api
  class SetupController < ActionController::API
    # One-time database setup endpoint for Render free tier
    # Call once after deployment: GET https://your-app.onrender.com/api/setup?token=YOUR_SECRET
    
    def create
      # Check token
      if params[:token] != ENV['SETUP_TOKEN']
        return render json: { error: 'Invalid token' }, status: :unauthorized
      end

      # Check if already setup
      if User.exists?(email: 't+admin@renterinsight.com')
        return render json: { 
          message: '✅ Already setup! Admin user exists.',
          admin_email: 't+admin@renterinsight.com'
        }, status: :ok
      end

      begin
        # Create production users
        admin = User.create!(
          email: 't+admin@renterinsight.com',
          password: 'Mindzenty1!',
          password_confirmation: 'Mindzenty1!',
          first_name: 'Tom',
          last_name: 'Admin',
          role: 'admin',
          status: 'active'
        )

        client = User.create!(
          email: 't+client@renterinsight.com',
          password: 'password123',
          password_confirmation: 'password123',
          first_name: 'Tom',
          last_name: 'Client',
          role: 'client',
          status: 'active'
        )

        render json: {
          message: '🎉 Setup complete!',
          users_created: [
            { email: admin.email, role: admin.role },
            { email: client.email, role: client.role }
          ],
          login_url: "#{request.base_url}/api/auth/login",
          admin_credentials: {
            email: 't+admin@renterinsight.com',
            password: 'Mindzenty1!'
          }
        }, status: :created

      rescue => e
        render json: { 
          error: 'Setup failed', 
          details: e.message,
          backtrace: e.backtrace.first(5)
        }, status: :unprocessable_entity
      end
    end
  end
end

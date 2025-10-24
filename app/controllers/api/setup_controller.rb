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
          admin_email: 't+admin@renterinsight.com',
          company: Company.first&.name || 'No company created yet'
        }, status: :ok
      end

      begin
        # Create default company first
        company = Company.create!(
          name: 'Demo RV Dealership',
          phone: '(555) 123-4567',
          email: 'info@demodealer.com',
          address: '123 Main Street',
          city: 'Denver',
          state: 'CO',
          zip: '80202',
          website: 'https://crm.landlordinsight.com'
        )

        # Create default sources
        sources = [
          Source.create!(id: 1, name: 'Web', source_type: 'online', is_active: true),
          Source.create!(id: 2, name: 'Referral', source_type: 'direct', is_active: true),
          Source.create!(id: 3, name: 'Walk-in', source_type: 'direct', is_active: true)
        ]

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
          company_created: {
            name: company.name,
            email: company.email
          },
          sources_created: sources.map { |s| { id: s.id, name: s.name } },
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

    # Separate endpoint to create sources
    def create_sources
      # Check token
      if params[:token] != ENV['SETUP_TOKEN']
        return render json: { error: 'Invalid token' }, status: :unauthorized
      end

      begin
        # Check if sources already exist
        if Source.count > 0
          return render json: {
            message: '✅ Sources already exist!',
            sources: Source.all.map { |s| { id: s.id, name: s.name, type: s.source_type } }
          }, status: :ok
        end

        # Create default sources
        sources = [
          Source.create!(id: 1, name: 'Web', source_type: 'online', is_active: true),
          Source.create!(id: 2, name: 'Referral', source_type: 'direct', is_active: true),
          Source.create!(id: 3, name: 'Walk-in', source_type: 'direct', is_active: true)
        ]

        render json: {
          message: '🎉 Sources created successfully!',
          sources_created: sources.map { |s| { id: s.id, name: s.name, type: s.source_type } }
        }, status: :created
      rescue => e
        render json: {
          error: 'Failed to create sources',
          details: e.message
        }, status: :unprocessable_entity
      end
    end
  end
end

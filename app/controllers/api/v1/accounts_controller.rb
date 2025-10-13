# frozen_string_literal: true

module Api
  module V1
    class AccountsController < ApplicationController
      before_action :set_account, only: %i[show update destroy convert_to_customer add_tags remove_tag activities deals insights score]

      # GET /api/v1/accounts
      def index
        @accounts = Account.active.includes(:tags, :source, :owner)
        
        # Apply filters
        @accounts = @accounts.where(account_type: params[:type]) if params[:type].present?
        @accounts = @accounts.where(rating: params[:rating]) if params[:rating].present?
        @accounts = @accounts.where(status: params[:status]) if params[:status].present?
        @accounts = @accounts.search(params[:q]) if params[:q].present?
        
        # Simple pagination without kaminari gem
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 25).to_i
        offset = (page - 1) * per_page
        
        total_count = @accounts.count
        @accounts = @accounts.limit(per_page).offset(offset)
        
        render json: {
          accounts: @accounts.as_json,
          meta: {
            current_page: page,
            total_pages: (total_count.to_f / per_page).ceil,
            total_count: total_count
          }
        }
      end

      # GET /api/v1/accounts/:id
      def show
        render json: @account.as_json
      end

      # POST /api/v1/accounts
      def create
        @account = Account.new(account_params)
        @account.company_id = current_company&.id
        @account.owner_id = current_user&.id
        
        # Set default values for required fields
        @account.status ||= 'active'
        @account.account_type ||= 'prospect'
        
        # Clean up website field
        if @account.website.blank?
          @account.website = nil
        end
        
        if @account.save
          # Handle tags
          if params[:tags].present?
            tag_names = params[:tags].is_a?(Array) ? params[:tags] : params[:tags].split(',')
            tag_names.each do |tag_name|
              tag = Tag.find_or_create_by!(name: tag_name.strip)
              @account.tag_assignments.create!(tag: tag, assigned_at: Time.current)
            end
          end
          
          render json: @account.as_json, status: :created
        else
          render json: { errors: @account.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/accounts/:id
      def update
        # Clean up website field if blank
        if params.key?(:website) && params[:website].blank?
          params[:website] = nil
        end
        
        if @account.update(account_params)
          # Handle tags if provided
          if params.key?(:tags)
            # Clear existing tags
            @account.tag_assignments.destroy_all
            
            # Add new tags
            if params[:tags].present?
              tag_names = params[:tags].is_a?(Array) ? params[:tags] : params[:tags].split(',')
              tag_names.each do |tag_name|
                tag = Tag.find_or_create_by!(name: tag_name.strip)
                @account.tag_assignments.create!(tag: tag, assigned_at: Time.current)
              end
            end
          end
          
          render json: @account.as_json
        else
          render json: { errors: @account.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/accounts/:id
      def destroy
        @account.soft_delete!
        head :no_content
      end

      # POST /api/v1/accounts/:id/convert_to_customer
      def convert_to_customer
        @account.convert_to_customer!
        render json: @account.as_json
      end

      # POST /api/v1/accounts/:id/tags
      def add_tags
        tag_names = params[:tags] || []
        tag_names = tag_names.split(',') if tag_names.is_a?(String)
        
        tag_names.each do |tag_name|
          tag = Tag.find_or_create_by!(name: tag_name.strip)
          @account.tag_assignments.find_or_create_by!(tag: tag) do |assignment|
            assignment.assigned_at = Time.current
          end
        end
        
        render json: @account.as_json
      end

      # DELETE /api/v1/accounts/:id/tags/:tag_name
      def remove_tag
        tag = Tag.find_by(name: params[:tag_name])
        @account.tag_assignments.where(tag: tag).destroy_all if tag
        render json: @account.as_json
      end

      # GET /api/v1/accounts/:id/activities
      def activities
        activities = @account.lead_activities.includes(:lead).order(created_at: :desc)
        
        # Simple pagination
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 25).to_i
        offset = (page - 1) * per_page
        
        total_count = activities.count
        activities = activities.limit(per_page).offset(offset)
        
        render json: {
          activities: activities.as_json(include: :lead),
          meta: {
            current_page: page,
            total_pages: (total_count.to_f / per_page).ceil,
            total_count: total_count
          }
        }
      end

      # GET /api/v1/accounts/:id/deals
      def deals
        # Placeholder until Deal model exists
        render json: {
          deals: [],
          meta: {
            current_page: 1,
            total_pages: 0,
            total_count: 0
          }
        }
        
        # Original implementation for when Deal model exists:
        # deals = @account.deals.order(created_at: :desc)
        # 
        # # Simple pagination
        # page = (params[:page] || 1).to_i
        # per_page = (params[:per_page] || 25).to_i
        # offset = (page - 1) * per_page
        # 
        # total_count = deals.count
        # deals = deals.limit(per_page).offset(offset)
        # 
        # render json: {
        #   deals: deals.as_json,
        #   meta: {
        #     current_page: page,
        #     total_pages: (total_count.to_f / per_page).ceil,
        #     total_count: total_count
        #   }
        # }
      end

      # GET /api/v1/accounts/stats
      def stats
        render json: {
          total: Account.active.count,
          by_type: Account.active.group(:account_type).count,
          by_status: Account.active.group(:status).count,
          by_rating: Account.active.group(:rating).count,
          recent_conversions: Account.where('converted_date >= ?', 30.days.ago).count,
          high_value: Account.high_value.count
        }
      end

      # GET /api/v1/accounts/industries
      def industries
        industries = Account.active.where.not(industry: [nil, '']).distinct.pluck(:industry)
        render json: industries
      end

      # GET /api/v1/accounts/export
      def export
        accounts = Account.active.includes(:tags, :source, :owner)
        
        # Apply filters
        accounts = accounts.where(account_type: params[:type]) if params[:type].present?
        accounts = accounts.where(rating: params[:rating]) if params[:rating].present?
        accounts = accounts.where(status: params[:status]) if params[:status].present?
        accounts = accounts.search(params[:q]) if params[:q].present?
        
        # Generate CSV
        csv_data = CSV.generate(headers: true) do |csv|
          csv << ['Name', 'Email', 'Phone', 'Type', 'Status', 'Rating', 'Industry', 'Website', 'Owner', 'Source', 'Tags', 'Created Date']
          
          accounts.find_each do |account|
            csv << [
              account.name,
              account.email,
              account.phone,
              account.account_type,
              account.status,
              account.rating,
              account.industry,
              account.website,
              account.owner&.name,
              account.source&.name,
              account.tags.pluck(:name).join(', '),
              account.created_at.strftime('%Y-%m-%d')
            ]
          end
        end
        
        send_data csv_data, filename: "accounts_#{Date.current}.csv", type: 'text/csv'
      end

      # POST /api/v1/accounts/convert_lead
      def convert_lead
        lead = Lead.find(params[:lead_id])
        
        # Create account from lead
        account = Account.create!(
          name: lead.name || "#{lead.first_name} #{lead.last_name}",
          email: lead.email,
          phone: lead.phone,
          status: 'active',
          account_type: 'prospect',
          source_id: lead.source_id,
          owner_id: current_user&.id,
          company_id: current_company&.id,
          billing_street: lead.street,
          billing_city: lead.city,
          billing_state: lead.state,
          billing_postal_code: lead.postal_code,
          billing_country: lead.country || 'USA'
        )
        
        # Copy tags
        lead.tags.each do |tag|
          account.tag_assignments.create!(tag: tag, assigned_at: Time.current)
        end
        
        # Update lead
        lead.update!(
          converted_account_id: account.id,
          conversion_date: Time.current,
          status: 'converted'
        )
        
        render json: account.as_json
      end

      # POST /api/v1/accounts/bulk_update
      def bulk_update
        account_ids = params[:account_ids] || []
        update_attrs = params[:attributes] || {}
        
        accounts = Account.where(id: account_ids)
        accounts.update_all(update_attrs.permit(:status, :rating, :account_type, :owner_id))
        
        render json: { updated_count: accounts.count }
      end

      # GET /api/v1/accounts/:id/insights
      def insights
        # Get communications for this account
        communications = Communication.where(communicable: @account)
                                     .order(created_at: :desc)
                                     .limit(50)
        
        # Get recent activities - Account has 'activities' association, not 'account_activities'
        activities = @account.activities
                             .order(created_at: :desc)
                             .limit(20)
        
        # Get communication stats
        total_communications = communications.count
        email_count = communications.where(channel: 'email').count
        sms_count = communications.where(channel: 'sms').count
        
        # Get recent notes
        notes = Note.where(entity_type: 'account', entity_id: @account.id)
                   .order(created_at: :desc)
                   .limit(10)
        
        # Calculate engagement score
        engagement_score = calculate_engagement_score(@account, communications)
        
        render json: {
          account_id: @account.id,
          account_name: @account.name,
          engagement_score: engagement_score,
          communication_stats: {
            total: total_communications,
            email: email_count,
            sms: sms_count,
            last_contact: communications.first&.created_at
          },
          recent_communications: communications.limit(10).map { |c| 
            {
              id: c.id,
              channel: c.channel,
              direction: c.direction,
              status: c.status,
              subject: c.subject,
              body: c.body&.truncate(100),
              created_at: c.created_at
            }
          },
          recent_activities: activities.map { |a|
            {
              id: a.id,
              activity_type: a.activity_type,
              title: a.title,
              status: a.status,
              due_date: a.due_date,
              created_at: a.created_at
            }
          },
          recent_notes: notes.map { |n|
            {
              id: n.id,
              content: n.content&.truncate(200),
              created_at: n.created_at
            }
          },
          insights: generate_insights(@account, communications, activities)
        }
      end

      # GET /api/v1/accounts/:id/score
      def score
        score_data = {
          account_id: @account.id,
          account_name: @account.name,
          activity_score: @account.activity_score || 0,
          engagement_level: determine_engagement_level(@account),
          scores: {
            communication: calculate_communication_score(@account),
            activity: calculate_activity_score(@account),
            recency: calculate_recency_score(@account),
            value: calculate_value_score(@account)
          },
          recommendations: generate_recommendations(@account)
        }
        
        render json: score_data
      end

      private

      def set_account
        @account = Account.find(params[:id])
      end

      def account_params
        params.permit(
          :name, :email, :phone, :website, :industry, :account_type, :status,
          :rating, :ownership, :annual_revenue, :employee_count, :description,
          :billing_street, :billing_city, :billing_state, :billing_postal_code, :billing_country,
          :shipping_street, :shipping_city, :shipping_state, :shipping_postal_code, :shipping_country,
          :parent_account_id, :source_id, :owner_id, :notes
        )
      end

      def current_company
        # This should be implemented based on your authentication/authorization system
        # For now, return the first company or nil
        ::Company.first
      end

      def current_user
        # This should be implemented based on your authentication/authorization system
        # For now, return the first user or nil
        ::User.first
      end

      # Helper methods for insights and scoring
      
      def calculate_engagement_score(account, communications)
        # Simple engagement score based on communication frequency and recency
        recent_comms = communications.where('created_at > ?', 30.days.ago).count
        recency_score = communications.any? ? [(30 - (Time.current - communications.first.created_at) / 1.day).to_i, 0].max : 0
        
        score = (recent_comms * 5) + recency_score
        [score, 100].min # Cap at 100
      end
      
      def generate_insights(account, communications, activities)
        insights = []
        
        # Communication insights
        if communications.empty?
          insights << {
            type: 'warning',
            title: 'No Communication History',
            message: 'No communications found with this account. Consider reaching out.'
          }
        elsif communications.where('created_at > ?', 30.days.ago).empty?
          insights << {
            type: 'warning',
            title: 'Inactive Account',
            message: 'No communication in the last 30 days. Account may need attention.'
          }
        else
          recent = communications.where('created_at > ?', 7.days.ago).count
          if recent > 5
            insights << {
              type: 'success',
              title: 'Highly Active',
              message: "#{recent} communications in the last 7 days. Great engagement!"
            }
          end
        end
        
        # Activity insights
        pending_activities = activities.where(status: 'pending').count
        if pending_activities > 0
          insights << {
            type: 'info',
            title: 'Pending Activities',
            message: "#{pending_activities} pending #{pending_activities == 1 ? 'activity' : 'activities'} require attention."
          }
        end
        
        # Overdue activities
        overdue = activities.where('due_date < ? AND status = ?', Time.current, 'pending').count
        if overdue > 0
          insights << {
            type: 'error',
            title: 'Overdue Activities',
            message: "#{overdue} #{overdue == 1 ? 'activity is' : 'activities are'} overdue."
          }
        end
        
        insights
      end
      
      def determine_engagement_level(account)
        score = account.activity_score || 0
        
        if score > 75
          'high'
        elsif score > 40
          'medium'
        else
          'low'
        end
      end
      
      def calculate_communication_score(account)
        comms = Communication.where(communicable: account)
        recent = comms.where('created_at > ?', 30.days.ago).count
        
        [recent * 10, 100].min
      end
      
      def calculate_activity_score(account)
        activities = account.activities.where('created_at > ?', 30.days.ago)
        completed = activities.where(status: 'completed').count
        
        [completed * 15, 100].min
      end
      
      def calculate_recency_score(account)
        last_comm = Communication.where(communicable: account).order(created_at: :desc).first
        return 0 unless last_comm
        
        days_ago = (Time.current - last_comm.created_at) / 1.day
        
        if days_ago < 7
          100
        elsif days_ago < 14
          75
        elsif days_ago < 30
          50
        else
          25
        end
      end
      
      def calculate_value_score(account)
        # Base value on account type and rating
        type_score = case account.account_type
        when 'customer' then 100
        when 'prospect' then 60
        else 30
        end
        
        rating_multiplier = case account.rating
        when 'hot' then 1.0
        when 'warm' then 0.8
        when 'cold' then 0.5
        else 0.6
        end
        
        (type_score * rating_multiplier).to_i
      end
      
      def generate_recommendations(account)
        recommendations = []
        
        # Check last communication
        last_comm = Communication.where(communicable: account).order(created_at: :desc).first
        if !last_comm || last_comm.created_at < 30.days.ago
          recommendations << {
            priority: 'high',
            action: 'reach_out',
            message: 'Consider reaching out to maintain relationship'
          }
        end
        
        # Check for pending activities
        pending = account.activities.where(status: 'pending').count
        if pending > 3
          recommendations << {
            priority: 'medium',
            action: 'complete_activities',
            message: "Complete #{pending} pending activities"
          }
        end
        
        # Check account type and rating
        if account.account_type == 'prospect' && account.rating == 'hot'
          recommendations << {
            priority: 'high',
            action: 'convert',
            message: 'Hot prospect - consider converting to customer'
          }
        end
        
        recommendations
      end
    end
  end
end

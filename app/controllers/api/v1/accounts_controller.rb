# frozen_string_literal: true

module Api
  module V1
    class AccountsController < ApplicationController
      before_action :set_account, only: %i[show update destroy convert_to_customer add_tags remove_tag activities deals]

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
    end
  end
end

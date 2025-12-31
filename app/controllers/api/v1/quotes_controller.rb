# frozen_string_literal: true

require 'csv'

module Api
  module V1
    class QuotesController < ApplicationController
      before_action :set_company_scope
      before_action :set_quote, only: %i[show update destroy send_quote pdf tags add_tags remove_tag]

      # GET /api/v1/quotes
      def index
        return unless authorize_action!('finance', 'read')
        
        # STRICT TENANT ISOLATION: Only return quotes from current user's company
        # RBAC: Location-tier users only see their assigned locations
        @quotes = if current_user.uses_rbac?
          if current_user.effective_admin?  # Use RBAC-aware admin check
            @company.quotes.active
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              # Include quotes in assigned locations OR unassigned quotes (NULL location_id)
              @company.quotes.active.where("location_id IN (?) OR location_id IS NULL", location_ids)
            else
              @company.quotes.active
            end
          end
        else
          @company.quotes.active
        end
        
        # Apply strict location filter - only quotes explicitly assigned to selected location
        if Current.location_filtered?
          @quotes = @quotes.where(location_id: Current.location_id)
        end
        
        @quotes = @quotes.includes(:account, :contact)
        
        # Apply filters
        @quotes = @quotes.by_account(params[:account_id]) if params[:account_id].present?
        @quotes = @quotes.by_contact(params[:contact_id]) if params[:contact_id].present?
        @quotes = @quotes.by_customer(params[:customer_id]) if params[:customer_id].present?
        @quotes = @quotes.by_status(params[:status]) if params[:status].present?
        @quotes = @quotes.search(params[:search]) if params[:search].present?
        
        # Sorting
        sort_by = params[:sort_by] || 'created_at'
        sort_order = params[:sort_order] || 'desc'
        @quotes = @quotes.order("#{sort_by} #{sort_order}")
        
        # Simple pagination
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 25).to_i
        offset = (page - 1) * per_page
        
        total_count = @quotes.count
        @quotes = @quotes.limit(per_page).offset(offset)
        
        render json: {
          quotes: @quotes.as_json(include_account: true, include_contact: true),
          meta: {
            current_page: page,
            total_pages: (total_count.to_f / per_page).ceil,
            total_count: total_count,
            per_page: per_page
          }
        }
      end

      # GET /api/v1/quotes/:id
      def show
        return unless authorize_action!('finance', 'read')
        
        render json: @quote.as_json(include_account: true, include_contact: true)
      end

      # POST /api/v1/quotes
      def create
        return unless authorize_action!('finance', 'create')
        
        # Get quote params and convert to hash
        quote_params_hash = params.require(:quote).to_unsafe_h
        
        # Transform camelCase to snake_case
        transformed_params = {}
        quote_params_hash.each do |key, value|
          snake_key = key.to_s.underscore
          transformed_params[snake_key] = value
        end
        
        # Handle items array separately
        if transformed_params['items'].is_a?(Array)
          transformed_params['items'] = transformed_params['items'].map do |item|
            next item unless item.is_a?(Hash)
            item_transformed = {}
            item.each { |k, v| item_transformed[k.to_s.underscore] = v }
            item_transformed
          end
        end
        
        # Create quote with safe params + STRICT TENANT ISOLATION
        safe_params = transformed_params.slice(
          'account_id',
          'contact_id',
          'customer_id',
          'vehicle_id',
          'status',
          'subtotal',
          'tax',
          'total',
          'valid_until',
          'notes',
          'items',
          'custom_fields'
        )
        
        @quote = @company.quotes.new(safe_params)
        
        # Auto-assign location from Current.location_id (set by X-Location-ID header)
        # This handles both admin users who selected a location and location-tier users
        if Current.location_id.present?
          @quote.location_id ||= Current.location_id
        elsif current_user.uses_rbac? && !current_user.effective_admin?
          # Fallback for RBAC location-tier users without header
          location_ids = permission_service.accessible_location_ids
          @quote.location_id ||= location_ids.first if location_ids.any?
        end
        
        # Set default valid_until if not provided (30 days from now)
        @quote.valid_until ||= 30.days.from_now.to_date
        
        if @quote.save
          render json: @quote.as_json(include_account: true, include_contact: true), status: :created
        else
          render json: { errors: @quote.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error creating quote: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH/PUT /api/v1/quotes/:id
      def update
        return unless authorize_action!('finance', 'update')
        
        # Get quote params and convert to hash
        quote_params_hash = params.require(:quote).to_unsafe_h
        
        # Transform camelCase to snake_case
        transformed_params = {}
        quote_params_hash.each do |key, value|
          snake_key = key.to_s.underscore
          transformed_params[snake_key] = value
        end
        
        # Handle items array separately
        if transformed_params['items'].is_a?(Array)
          transformed_params['items'] = transformed_params['items'].map do |item|
            next item unless item.is_a?(Hash)
            item_transformed = {}
            item.each { |k, v| item_transformed[k.to_s.underscore] = v }
            item_transformed
          end
        end
        
        # Create quote with safe params
        safe_params = transformed_params.slice(
          'account_id',
          'contact_id',
          'customer_id',
          'vehicle_id',
          'status',
          'subtotal',
          'tax',
          'total',
          'valid_until',
          'notes',
          'items',
          'custom_fields'
        )
        
        if @quote.update(safe_params)
          render json: @quote.as_json(include_account: true, include_contact: true)
        else
          render json: { errors: @quote.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error updating quote: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/quotes/:id
      def destroy
        return unless authorize_action!('finance', 'delete')
        
        @quote.soft_delete!
        head :no_content
      end

      # POST /api/v1/quotes/:id/send
      def send_quote
        return unless authorize_action!('finance', 'update')
        
        # Extract send parameters
        send_params = params.permit(
          :to_email,
          :to_phone,
          :custom_message,
          :template_id,
          :send_async,
          :from_email,
          :from_phone,
          :cc,
          :bcc,
          delivery_methods: []
        ).to_h
        
        # Default to email if no delivery methods specified
        send_params[:delivery_methods] ||= ['email']
        
        # Convert to symbols for service
        send_params_symbolized = send_params.deep_symbolize_keys
        
        # Use QuoteSendingService to send the quote
        begin
          result = QuoteSendingService.new(@quote).send(**send_params_symbolized)
          
          if result[:sent].any?
            # Update quote status
            @quote.send! if @quote.may_send?
            
            render json: {
              success: true,
              quote: @quote.as_json(include_account: true, include_contact: true),
              sent_via: result[:sent].map { |r| { channel: r[:channel], to: r[:to] } },
              communications: result[:sent].map { |r| r[:communication]&.id }
            }
          else
            render json: {
              success: false,
              error: result[:errors].first || 'Failed to send quote',
              errors: result[:errors],
              failed: result[:failed]
            }, status: :unprocessable_entity
          end
        rescue ArgumentError => e
          render json: { success: false, error: e.message }, status: :bad_request
        rescue => e
          Rails.logger.error "Error sending quote: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          render json: { success: false, error: e.message }, status: :internal_server_error
        end
      end

      # GET /api/v1/quotes/stats
      def stats
        return unless authorize_action!('finance', 'read')
        
        # STRICT TENANT ISOLATION: Only stats from current user's company
        quotes = @company.quotes.active
        
        # Apply strict location filter - only quotes explicitly assigned to selected location
        if Current.location_filtered?
          quotes = quotes.where(location_id: Current.location_id)
        end
        
        render json: {
          total: quotes.count,
          by_status: quotes.group(:status).count,
          total_value: quotes.sum(:total),
          average_value: quotes.average(:total)&.to_f || 0,
          recent_count: quotes.where('created_at >= ?', 30.days.ago).count
        }
      end

      # POST /api/v1/quotes/:id/accept
      def accept
        return unless authorize_action!('finance', 'update')
        
        set_quote
        if @quote.accept!
          render json: @quote.as_json(include_account: true, include_contact: true)
        else
          render json: { error: 'Cannot accept quote in current status' }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/quotes/:id/reject
      def reject
        return unless authorize_action!('finance', 'update')
        
        set_quote
        if @quote.reject!
          render json: @quote.as_json(include_account: true, include_contact: true)
        else
          render json: { error: 'Cannot reject quote in current status' }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/quotes/:id/pdf
      def pdf
        return unless authorize_action!('finance', 'read')
        
        pdf_content = QuotePdfGenerator.new(@quote).generate
        
        send_data pdf_content,
          filename: "#{@quote.quote_number}.pdf",
          type: 'application/pdf',
          disposition: 'inline' # Opens in browser instead of downloading
      rescue => e
        Rails.logger.error "Error generating PDF: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: 'Failed to generate PDF', message: e.message }, status: :internal_server_error
      end

      # GET /api/v1/quotes/:id/tags
      def tags
        return unless authorize_action!('finance', 'read')
        
        # Get tags through the association
        tags = @quote.tags.map do |tag|
          {
            id: tag.id,
            name: tag.name,
            description: tag.description,
            color: tag.color,
            category: tag.category,
            type: tag.try(:tag_type),
            isSystem: tag.try(:is_system),
            isActive: tag.try(:is_active),
            usageCount: tag.usage_count,
            createdBy: tag.try(:created_by),
            createdAt: tag.created_at,
            updatedAt: tag.updated_at
          }.compact
        end
        
        render json: tags
      end

      # POST /api/v1/quotes/:id/tags
      def add_tags
        return unless authorize_action!('finance', 'update')
        
        tag_names = params[:tags] || []
        tag_names = tag_names.split(',') if tag_names.is_a?(String)
        
        tag_names.each do |tag_name|
          # Find or create tag within current company scope
          tag = @company.tags.find_or_create_by!(name: tag_name.strip) do |new_tag|
            new_tag.color = '#6B7280'
            new_tag.is_active = true
            new_tag.created_by = current_user&.id&.to_s || 'system'
          end
          
          # Create tag assignment using polymorphic association
          TagAssignment.find_or_create_by!(
            tag: tag,
            entity_type: 'Quote',
            entity_id: @quote.id
          ) do |assignment|
            assignment.company_id = @company.id
            assignment.assigned_by = current_user&.id&.to_s || 'system'
            assignment.assigned_at = Time.current
          end
        end
        
        # Reload tags association to get updated list
        @quote.reload
        render json: @quote.as_json(include_account: true, include_contact: true)
      end

      # DELETE /api/v1/quotes/:id/tags/:tag_name
      def remove_tag
        return unless authorize_action!('finance', 'update')
        
        # Find tag within company scope
        tag = @company.tags.find_by(name: params[:tag_name])
        
        if tag
          # Remove tag assignment using polymorphic association
          TagAssignment.where(
            tag: tag,
            entity_type: 'Quote',
            entity_id: @quote.id
          ).destroy_all
        end
        
        # Reload tags association to get updated list
        @quote.reload
        render json: @quote.as_json(include_account: true, include_contact: true)
      end

      # GET /api/v1/quotes/export
      def export
        return unless authorize_action!('finance', 'export')
        
        # STRICT TENANT ISOLATION: Only export quotes from current user's company
        quotes = @company.quotes.active.includes(:account, :contact)
        
        # Apply strict location filter - only quotes explicitly assigned to selected location
        if Current.location_filtered?
          quotes = quotes.where(location_id: Current.location_id)
        end
        
        # Apply same filters as index
        quotes = quotes.by_account(params[:account_id]) if params[:account_id].present?
        quotes = quotes.by_contact(params[:contact_id]) if params[:contact_id].present?
        quotes = quotes.by_customer(params[:customer_id]) if params[:customer_id].present?
        quotes = quotes.by_status(params[:status]) if params[:status].present?
        quotes = quotes.search(params[:search]) if params[:search].present?
        
        # Generate CSV
        csv_data = CSV.generate(headers: true) do |csv|
          csv << ['Quote Number', 'Status', 'Account', 'Contact', 'Subtotal', 'Tax', 'Total', 'Valid Until', 'Created Date']
          
          quotes.find_each do |quote|
            csv << [
              quote.quote_number,
              quote.status,
              quote.account&.name,
              quote.contact ? "#{quote.contact.first_name} #{quote.contact.last_name}" : '',
              quote.subtotal,
              quote.tax,
              quote.total,
              quote.valid_until,
              quote.created_at.strftime('%Y-%m-%d')
            ]
          end
        end
        
        send_data csv_data, filename: "quotes_#{Date.current}.csv", type: 'text/csv'
      end

      private

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [QuotesController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [QuotesController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [QuotesController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [QuotesController] Company scope set: #{@company.name} (ID: #{@company.id}) for user: #{current_user.email}"
      end

      def set_quote
        # STRICT TENANT ISOLATION: Only find quotes within company
        # RBAC: Location-tier users only access their assigned locations
        @quote = if current_user.uses_rbac? && !current_user.effective_admin?  # Use RBAC-aware admin check
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            # Include quotes in assigned locations OR unassigned quotes (NULL location_id)
            @company.quotes.where("location_id IN (?) OR location_id IS NULL", location_ids).find(params[:id])
          else
            @company.quotes.find(params[:id])
          end
        else
          @company.quotes.find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Quote not found or access denied' }, status: :not_found
        return
      end
    end
  end
end

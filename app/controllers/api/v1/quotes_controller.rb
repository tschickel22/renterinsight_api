# frozen_string_literal: true

module Api
  module V1
    class QuotesController < ApplicationController
      before_action :set_quote, only: %i[show update destroy send_quote]

      # GET /api/v1/quotes
      def index
        @quotes = Quote.active.includes(:account, :contact)
        
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
        render json: @quote.as_json(include_account: true, include_contact: true)
      end

      # POST /api/v1/quotes
      def create
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
        
        @quote = Quote.new(safe_params)
        
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
        @quote.soft_delete!
        head :no_content
      end

      # POST /api/v1/quotes/:id/send
      def send_quote
        if @quote.send!
          render json: @quote.as_json(include_account: true, include_contact: true)
        else
          render json: { error: 'Cannot send quote in current status' }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/quotes/stats
      def stats
        quotes = Quote.active
        
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
        set_quote
        if @quote.accept!
          render json: @quote.as_json(include_account: true, include_contact: true)
        else
          render json: { error: 'Cannot accept quote in current status' }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/quotes/:id/reject
      def reject
        set_quote
        if @quote.reject!
          render json: @quote.as_json(include_account: true, include_contact: true)
        else
          render json: { error: 'Cannot reject quote in current status' }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/quotes/export
      def export
        quotes = Quote.active.includes(:account, :contact)
        
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

      def set_quote
        @quote = Quote.find(params[:id])
      end
    end
  end
end

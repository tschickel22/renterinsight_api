# frozen_string_literal: true

module Api
  module Partner
    module V1
      class QuotesController < BaseController
        include PartnerWebhooks
        fires_webhooks resource: :quote

        before_action :authorize_quotes
        before_action :set_quote, only: [:show, :update, :destroy]

        # GET /api/partner/v1/quotes
        def index
          quotes = company_scope(Quote).where(is_deleted: false)

          # Filters
          quotes = quotes.where(status: params[:status]) if params[:status].present?
          quotes = quotes.where(account_id: params[:account_id]) if params[:account_id].present?
          quotes = quotes.where(contact_id: params[:contact_id]) if params[:contact_id].present?
          quotes = quotes.where(vehicle_id: params[:vehicle_id]) if params[:vehicle_id].present?
          quotes = quotes.where(location_id: params[:location_id]) if params[:location_id].present?

          # Search
          if params[:q].present?
            q = "%#{params[:q]}%"
            quotes = quotes.where("quote_number ILIKE :q OR notes ILIKE :q", q: q)
          end

          # Cursor-based pagination
          quotes = quotes.order(:id)
          quotes = quotes.where("id > ?", params[:after].to_i) if params[:after].present?
          limit = [params.fetch(:limit, 50).to_i, 200].min
          quotes = quotes.limit(limit + 1)

          records = quotes.to_a
          has_more = records.size > limit
          records = records.first(limit)

          render json: {
            data: records.map { |q| quote_json(q) },
            meta: {
              has_more: has_more,
              next_cursor: has_more ? records.last&.id&.to_s : nil,
              limit: limit
            }
          }
        end

        # GET /api/partner/v1/quotes/:id
        def show
          render json: { data: quote_json(@quote, detailed: true) }
        end

        # POST /api/partner/v1/quotes
        def create
          quote = company_scope(Quote).new(quote_params)

          if quote.save
            render json: { data: quote_json(quote, detailed: true) }, status: :created
          else
            render json: { error: "Validation failed", details: quote.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # PATCH /api/partner/v1/quotes/:id
        def update
          if @quote.update(quote_params)
            render json: { data: quote_json(@quote, detailed: true) }
          else
            render json: { error: "Validation failed", details: @quote.errors.full_messages }, status: :unprocessable_entity
          end
        end

        # DELETE /api/partner/v1/quotes/:id
        def destroy
          @quote.update!(is_deleted: true, deleted_at: Time.current)
          render json: { data: { id: @quote.id, deleted: true } }
        end

        private

        def authorize_quotes
          case action_name
          when "index", "show"
            authorize_permission!(:quotes, :read)
          when "create"
            authorize_permission!(:quotes, :create)
          when "update"
            authorize_permission!(:quotes, :update)
          when "destroy"
            authorize_permission!(:quotes, :delete)
          end
        end

        def set_quote
          @quote = company_scope(Quote).where(is_deleted: false).find(params[:id])
        end

        def quote_params
          params.permit(
            :account_id, :contact_id, :vehicle_id, :location_id,
            :status, :valid_until, :notes, :tax,
            items: [:description, :quantity, :unit_price, :amount, :part_id, :sku],
            custom_fields: {}
          )
        end

        def quote_json(quote, detailed: false)
          json = {
            id: quote.id,
            quote_number: quote.quote_number,
            status: quote.status,
            subtotal: quote.subtotal,
            tax: quote.tax,
            total: quote.total,
            valid_until: quote.valid_until&.iso8601,
            account_id: quote.account_id,
            contact_id: quote.contact_id,
            vehicle_id: quote.vehicle_id,
            location_id: quote.location_id,
            created_at: quote.created_at&.iso8601,
            updated_at: quote.updated_at&.iso8601
          }

          if detailed
            json.merge!(
              items: quote.items,
              notes: quote.notes,
              custom_fields: quote.custom_fields,
              sent_at: quote.sent_at&.iso8601,
              viewed_at: quote.viewed_at&.iso8601,
              accepted_at: quote.accepted_at&.iso8601,
              rejected_at: quote.rejected_at&.iso8601,
              resend_count: quote.resend_count,
              last_sent_at: quote.last_sent_at&.iso8601
            )
          end

          json
        end
      end
    end
  end
end

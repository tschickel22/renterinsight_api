# frozen_string_literal: true

module Api
  module Portal
    class QuotesController < ApplicationController
      skip_before_action :authenticate
      before_action :authenticate_portal_buyer!
      before_action :set_quote, only: [:show, :accept, :reject]
      before_action :authorize_quote_access!, only: [:show, :accept, :reject]

      # GET /api/portal/quotes
      def index
        quotes = buyer_quotes

        # Filter by status if provided
        if params[:status].present?
          quotes = quotes.where(status: params[:status])
        end

        # Pagination
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 20).to_i, 100].min

        total_count = quotes.count
        total_pages = (total_count.to_f / per_page).ceil

        quotes = quotes.order(created_at: :desc)
                       .limit(per_page)
                       .offset((page - 1) * per_page)

        render json: {
          ok: true,
          quotes: quotes.as_json,
          pagination: {
            current_page: page,
            total_pages: total_pages,
            total_count: total_count,
            per_page: per_page
          }
        }
      end

      # GET /api/portal/quotes/:id
      def show
        # Mark as viewed on first view (if currently 'sent')
        if @quote.status == 'sent'
          @quote.update(status: 'viewed', updated_at: Time.current)
        end

        render json: {
          ok: true,
          quote: @quote.as_json
        }
      end

      # POST /api/portal/quotes/:id/accept
      def accept
        unless %w[sent viewed].include?(@quote.status)
          return render json: {
            ok: false,
            error: "Quote cannot be accepted. Current status: #{@quote.status}"
          }, status: :unprocessable_entity
        end

        @quote.update!(status: 'accepted', updated_at: Time.current)

        create_quote_note(@quote, 'accepted', params[:notes])

        render json: {
          ok: true,
          message: 'Quote accepted successfully',
          quote: @quote
        }
      end

      # POST /api/portal/quotes/:id/reject
      def reject
        unless %w[sent viewed].include?(@quote.status)
          return render json: {
            ok: false,
            error: "Quote cannot be rejected. Current status: #{@quote.status}"
          }, status: :unprocessable_entity
        end

        @quote.update!(status: 'rejected', updated_at: Time.current)

        create_quote_note(@quote, 'rejected', params[:reason])

        render json: {
          ok: true,
          message: 'Quote rejected',
          quote: @quote
        }
      end

      private

      def set_quote
        @quote = Quote.find_by(id: params[:id])
        unless @quote
          render json: { ok: false, error: 'Quote not found' }, status: :not_found
        end
      end

      def authorize_quote_access!
        buyer_portal_access = current_portal_buyer
        account = buyer_portal_access.buyer_type.constantize.find_by(id: buyer_portal_access.buyer_id)
        
        unless @quote.account_id == account.id
          render json: { ok: false, error: 'Unauthorized' }, status: :forbidden
        end
      end

      def buyer_quotes
        buyer_portal_access = current_portal_buyer
        account = buyer_portal_access.buyer_type.constantize.find_by(id: buyer_portal_access.buyer_id)
        Quote.where(account_id: account.id)
      end

      def create_quote_note(quote, action, content)
        note_content = "Quote #{action} by client"
        note_content += ": #{content}" if content.present?

        buyer_portal_access = current_portal_buyer
        user = User.find_by(email: buyer_portal_access.email, role: 'client')
        
        Note.create!(
          entity_type: 'quote',
          entity_id: quote.id.to_s,
          content: note_content,
          created_by: user&.id&.to_s || buyer_portal_access.email,
          created_by_name: user ? "#{user.first_name} #{user.last_name}".strip : buyer_portal_access.email
        )
      end
    end
  end
end

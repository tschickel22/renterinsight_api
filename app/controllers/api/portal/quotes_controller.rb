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
          quotes = quotes.by_status(params[:status])
        end
        
        # Pagination
        page = (params[:page] || 1).to_i
        per_page = [(params[:per_page] || 20).to_i, 100].min # Max 100 per page
        
        total_count = quotes.count
        total_pages = (total_count.to_f / per_page).ceil
        
        quotes = quotes.order(created_at: :desc)
                       .limit(per_page)
                       .offset((page - 1) * per_page)
        
        render json: {
          ok: true,
          quotes: quotes.map { |q| QuotePresenter.basic_json(q) },
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
        if @quote.status == 'sent' && @quote.viewed_at.nil?
          @quote.update!(status: 'viewed', viewed_at: Time.current)
        end
        
        render json: {
          ok: true,
          quote: QuotePresenter.detailed_json(@quote)
        }
      end
      
      # POST /api/portal/quotes/:id/accept
      def accept
        # Validate quote can be accepted
        unless %w[sent viewed].include?(@quote.status)
          return render json: {
            ok: false,
            error: "Quote cannot be accepted. Current status: #{@quote.status}"
          }, status: :unprocessable_entity
        end
        
        # Check if expired
        if @quote.expired?
          return render json: {
            ok: false,
            error: 'Quote has expired and cannot be accepted'
          }, status: :unprocessable_entity
        end
        
        # Accept the quote
        @quote.update!(
          status: 'accepted',
          accepted_at: Time.current
        )
        
        # Create note with acceptance
        create_quote_note(@quote, 'accepted', params[:notes])
        
        render json: {
          ok: true,
          message: 'Quote accepted successfully',
          quote: {
            id: @quote.id,
            quote_number: @quote.quote_number,
            status: @quote.status,
            accepted_at: @quote.accepted_at
          }
        }
      end
      
      # POST /api/portal/quotes/:id/reject
      def reject
        # Validate quote can be rejected
        unless %w[sent viewed].include?(@quote.status)
          return render json: {
            ok: false,
            error: "Quote cannot be rejected. Current status: #{@quote.status}"
          }, status: :unprocessable_entity
        end
        
        # Check if expired
        if @quote.expired?
          return render json: {
            ok: false,
            error: 'Quote has expired and cannot be rejected'
          }, status: :unprocessable_entity
        end
        
        # Reject the quote
        @quote.update!(
          status: 'rejected',
          rejected_at: Time.current
        )
        
        # Create note with rejection reason
        create_quote_note(@quote, 'rejected', params[:reason])
        
        render json: {
          ok: true,
          message: 'Quote rejected',
          quote: {
            id: @quote.id,
            quote_number: @quote.quote_number,
            status: @quote.status,
            rejected_at: @quote.rejected_at
          }
        }
      end
      
      private
      
      def set_quote
        @quote = Quote.find_by(id: params[:id], is_deleted: false)
        unless @quote
          render json: { ok: false, error: 'Quote not found' }, status: :not_found
        end
      end
      
      def authorize_quote_access!
        buyer = current_portal_buyer.buyer
        
        case buyer
        when Lead
          # Lead owns quote if quote.account matches lead's converted account
          unless buyer.is_converted && @quote.account_id == buyer.converted_account_id
            render json: { ok: false, error: 'Unauthorized' }, status: :forbidden
          end
        when Account
          # Account owns quote if quote.account == buyer
          unless @quote.account_id == buyer.id
            render json: { ok: false, error: 'Unauthorized' }, status: :forbidden
          end
        else
          render json: { ok: false, error: 'Unauthorized' }, status: :forbidden
        end
      end
      
      def buyer_quotes
        buyer = current_portal_buyer.buyer
        
        case buyer
        when Lead
          # Get quotes for the converted account
          if buyer.is_converted && buyer.converted_account_id.present?
            Quote.where(account_id: buyer.converted_account_id, is_deleted: false)
          else
            Quote.none
          end
        when Account
          # Get quotes directly for this account
          Quote.where(account_id: buyer.id, is_deleted: false)
        else
          Quote.none
        end
      end
      
      def create_quote_note(quote, action, content)
        note_content = "Quote #{action} by buyer"
        note_content += ": #{content}" if content.present?
        
        Note.create!(
          entity_type: 'Quote',
          entity_id: quote.id.to_s,
          content: note_content,
          created_by_name: "#{current_portal_buyer.buyer.try(:first_name)} #{current_portal_buyer.buyer.try(:last_name)}".strip
        )
      end
    end
  end
end

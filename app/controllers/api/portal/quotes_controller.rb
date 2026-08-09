# frozen_string_literal: true

module Api
  module Portal
    class QuotesController < ApplicationController
      skip_before_action :authenticate
      before_action :authenticate_portal_buyer!
      before_action :set_quote, only: [:show, :accept, :reject]

      # GET /api/portal/quotes
      def index
        quotes = buyer_quotes

        # FILTER OUT DRAFTS - clients should not see draft quotes
        quotes = quotes.where.not(status: 'draft')

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
            error: "Quote has already been #{@quote.status}. Current status: #{@quote.status}"
          }, status: :unprocessable_entity
        end

        # A quote past its valid_until has to be re-issued by the dealer; the
        # buyer must not be able to lock in stale pricing from the portal.
        if @quote.valid_until.present? && @quote.valid_until < Date.current
          return render json: {
            ok: false,
            error: "This quote expired on #{@quote.valid_until.to_fs(:long)}. Please ask for an updated quote."
          }, status: :unprocessable_entity
        end

        # accepted_at was never written, so the dealer had a status with no date
        # against it and the buyer's acceptance could not be evidenced.
        @quote.update!(status: 'accepted', accepted_at: Time.current, updated_at: Time.current)

        # Accept notes from client (multiple param names supported)
        notes = params[:notes] || params[:note] || params[:message]
        create_quote_note(@quote, 'accepted', notes)
        
        # Send notification email to company
        notify_company_quote_accepted(@quote)

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

        @quote.update!(status: 'rejected', rejected_at: Time.current, updated_at: Time.current)

        # Accept reason/notes from client (multiple param names supported)
        reason = params[:reason] || params[:notes] || params[:note] || params[:message]
        create_quote_note(@quote, 'rejected', reason)
        
        # Send notification email to company
        notify_company_quote_rejected(@quote, reason)

        render json: {
          ok: true,
          message: 'Quote rejected',
          quote: @quote
        }
      end

      private

      def set_quote
        # Scope quote lookup to buyer's quotes for tenant isolation
        @quote = buyer_quotes.find_by(id: params[:id])
        unless @quote
          render json: { ok: false, error: 'Quote not found' }, status: :not_found
        end
      end

      # FIXED: Properly handle polymorphic buyer relationship
      def buyer_quotes
        buyer_portal_access = current_portal_buyer
        
        # Handle polymorphic buyer relationship correctly
        case buyer_portal_access.buyer_type
        when 'Contact'
          contact = Contact.find_by(id: buyer_portal_access.buyer_id)
          return Quote.none unless contact
          
          # Find quotes by BOTH account_id AND contact_id
          # Company might set only account_id, only contact_id, or both
          Quote.where(company_id: contact.company_id)
               .where('account_id = ? OR contact_id = ?', contact.account_id, contact.id)
          
        when 'Account'
          account = Account.find_by(id: buyer_portal_access.buyer_id)
          return Quote.none unless account
          
          # For accounts, find all quotes for this account
          Quote.where(account_id: account.id, company_id: account.company_id)
          
        else
          # Unknown buyer type - return empty relation
          Rails.logger.warn "[Portal] Unknown buyer_type: #{buyer_portal_access.buyer_type}"
          Quote.none
        end
      end

      def create_quote_note(quote, action, content)
        note_content = "Quote #{action} by client via portal"
        note_content += ": #{content}" if content.present?

        buyer_portal_access = current_portal_buyer
        user = User.find_by(email: buyer_portal_access.email, role: 'client')
        
        Note.create!(
          entity_type: 'quote',
          entity_id: quote.id.to_s,
          content: note_content,
          user_id: user&.id,
          created_by_name: user ? "#{user.first_name} #{user.last_name}".strip : buyer_portal_access.email
        )
      rescue => e
        Rails.logger.error "[Portal] Failed to create quote note: #{e.message}"
      end
      
      def notify_company_quote_accepted(quote)
        QuoteMailer.client_accepted(quote).deliver_later
      rescue => e
        Rails.logger.error "[Portal] Failed to send quote accepted email: #{e.message}"
      end
      
      def notify_company_quote_rejected(quote, reason)
        QuoteMailer.client_rejected(quote, reason).deliver_later
      rescue => e
        Rails.logger.error "[Portal] Failed to send quote rejected email: #{e.message}"
      end
    end
  end
end

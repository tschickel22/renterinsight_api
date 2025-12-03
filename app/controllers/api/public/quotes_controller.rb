# frozen_string_literal: true

module Api
  module Public
    class QuotesController < ApplicationController
      skip_before_action :authenticate
      
      # GET /q/:token
      def show
        @quote = Quote.find_by!(public_token: params[:token])
        
        # Ensure quote is sent (not draft)
        if @quote.status == 'draft'
          render json: { error: 'Quote not found' }, status: :not_found
          return
        end
        
        # Mark as viewed on first view
        if @quote.status == 'sent'
          @quote.update(status: 'viewed', viewed_at: Time.current)
        end
        
        # Get company branding info - only use fields that exist on Company model
        company_info = {
          name: @quote.company.name
        }
        
        # Return JSON for frontend to display
        render json: {
          ok: true,
          quote: @quote.as_json.merge(
            company: company_info,
            contact: @quote.contact ? {
              first_name: @quote.contact.first_name,
              last_name: @quote.contact.last_name,
              email: @quote.contact.email,
              phone: @quote.contact.phone
            } : nil
          )
        }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Quote not found' }, status: :not_found
      end
      
      # POST /q/:token/accept
      def accept
        @quote = Quote.find_by!(public_token: params[:token])
        
        # Only allow accepting sent/viewed quotes
        unless ['sent', 'viewed'].include?(@quote.status)
          render json: { error: 'Quote cannot be accepted in current status' }, status: :unprocessable_entity
          return
        end
        
        # Update quote status
        @quote.update!(status: 'accepted', accepted_at: Time.current)
        
        # Create note if provided
        notes = params[:notes]
        if notes.present?
          create_quote_note(@quote, 'accepted', notes)
        end
        
        # Send notification email to company
        notify_company_quote_accepted(@quote)
        
        render json: { ok: true, quote: @quote.as_json }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Quote not found' }, status: :not_found
      end
      
      # POST /q/:token/reject
      def reject
        @quote = Quote.find_by!(public_token: params[:token])
        
        # Only allow rejecting sent/viewed quotes
        unless ['sent', 'viewed'].include?(@quote.status)
          render json: { error: 'Quote cannot be rejected in current status' }, status: :unprocessable_entity
          return
        end
        
        # Update quote status
        @quote.update!(status: 'rejected', rejected_at: Time.current)
        
        # Create note if provided
        reason = params[:reason] || params[:notes]
        if reason.present?
          create_quote_note(@quote, 'rejected', reason)
        end
        
        # Send notification email to company
        notify_company_quote_rejected(@quote, reason)
        
        render json: { ok: true, quote: @quote.as_json }
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Quote not found' }, status: :not_found
      end
      
      private
      
      def create_quote_note(quote, action, message)
        return if message.blank?
        
        Note.create!(
          entity_type: 'quote',
          entity_id: quote.id.to_s,
          content: "Quote #{action} by client via public link: #{message}",
          created_by_name: quote.contact ? "#{quote.contact.first_name} #{quote.contact.last_name}" : 'Client'
        )
      rescue => e
        Rails.logger.error "[Public Quotes] Failed to create note: #{e.message}"
      end
      
      def notify_company_quote_accepted(quote)
        QuoteMailer.client_accepted(quote).deliver_later
      rescue => e
        Rails.logger.error "[Public Quotes] Failed to send acceptance email: #{e.message}"
      end
      
      def notify_company_quote_rejected(quote, reason)
        QuoteMailer.client_rejected(quote, reason).deliver_later
      rescue => e
        Rails.logger.error "[Public Quotes] Failed to send rejection email: #{e.message}"
      end
    end
  end
end

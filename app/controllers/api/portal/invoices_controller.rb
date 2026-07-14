# frozen_string_literal: true

module Api
  module Portal
    class InvoicesController < ApplicationController
      skip_before_action :authenticate
      before_action :authenticate_portal_buyer!
      before_action :set_invoice, only: [:show, :payments, :make_payment, :download]

      # GET /api/portal/invoices
      def index
        contact = current_portal_buyer.buyer
        
        unless contact
          render json: { error: 'Contact not found' }, status: :not_found
          return
        end

        invoices = contact.invoices.where(is_deleted: [false, nil])

        # CRITICAL: Exclude draft invoices from portal - only show sent, partial, paid, overdue
        # Draft invoices are not yet ready to be shared with customers
        invoices = invoices.where.not(status: 'draft')

        # Filter by status if provided
        if params[:status].present?
          invoices = invoices.where(status: params[:status])
        end

        invoices = invoices.order(created_at: :desc)

        render json: invoices.map { |invoice| invoice_json(invoice) }
      end

      # GET /api/portal/invoices/:id
      def show
        render json: invoice_detail_json(@invoice)
      end

      # GET /api/portal/invoices/:id/payments
      def payments
        payments = @invoice.payments.order(payment_date: :desc)
        render json: payments.map { |payment| payment_json(payment) }
      end

      # POST /api/portal/invoices/:id/make_payment
      def make_payment
        amount = params[:amount].to_f
        payment_method_id = params[:payment_method_id]
        payment_method_data = params[:payment_method]

        # Validate amount
        if amount <= 0
          render json: { success: false, error: 'Amount must be greater than 0' }, status: :unprocessable_entity
          return
        end

        if amount > @invoice.amount_due
          render json: { success: false, error: 'Amount cannot exceed amount due' }, status: :unprocessable_entity
          return
        end

        # Handle payment method - either use saved or create new
        begin
          if payment_method_id.present?
            # Use existing saved payment method
            contact = current_portal_buyer.buyer
            payment_method = PaymentMethod.find_by(
              id: payment_method_id,
              owner_type: 'Contact',
              owner_id: contact.id,
              is_deleted: [false, nil]
            )
            
            unless payment_method
              render json: { success: false, error: 'Payment method not found' }, status: :not_found
              return
            end
          elsif payment_method_data.present?
            # Create and save new payment method
            payment_method = create_and_save_payment_method(payment_method_data)
          else
            render json: { success: false, error: 'Payment method is required' }, status: :unprocessable_entity
            return
          end
        rescue ActiveRecord::RecordInvalid => e
          Rails.logger.error "Payment method validation failed: #{e.record.errors.full_messages.join(', ')}"
          render json: { success: false, error: e.record.errors.full_messages.join(', ') }, status: :unprocessable_entity
          return
        rescue => e
          Rails.logger.error "Payment method error: #{e.class} - #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          render json: { success: false, error: "Payment method error: #{e.message}" }, status: :unprocessable_entity
          return
        end

        # Create payment record — application ties it to this invoice, so
        # once processing completes and status flips to 'completed' the
        # invoice's amount_paid recomputes from the joined applications.
        payment = @invoice.company.payments.build(
          amount: amount,
          payment_date: Date.today,
          payment_type: 'one_time',
          status: 'pending',
          payer: current_portal_buyer.buyer,
          payment_method_id: payment_method.id
        )

        if payment.save && payment.apply_to!(@invoice, amount: amount)
          # Process payment via Zego
          zego_api = RenterInsightZegoApi.new(@invoice.company)
          
          # Determine which Zego method to use based on whether payment method has external_id
          if payment_method.external_id.present?
            # Use saved payment method account
            success = zego_api.capture_portal_payment(payment_method, payment, request)
          else
            # New payment method - create account and save external_id
            success = zego_api.capture_portal_payment(payment_method, payment, request)
            
            if success
              # Save external_id from Zego to payment method for future reuse
              gateway_payer_id = zego_api.read_gateway_payer_id
              if gateway_payer_id.present?
                payment_method.update(
                  external_id: gateway_payer_id,
                  api_partner_id: RenterInsightZegoApi::API_PARTNER_ID
                )
              end
            end
          end

          if success
            
            # Update payment with transaction details
            payment.update(
              external_id: zego_api.read_transaction_id,
              status: zego_api.payment_pending? ? 'pending' : 'completed',
              processed_at: Time.current
            )

            # If completed, update invoice balance and send receipt
            if payment.status == 'completed'
              @invoice.update(
                amount_paid: @invoice.amount_paid + amount,
                amount_due: @invoice.amount_due - amount
              )

              # Update invoice status
              if @invoice.amount_due <= 0
                @invoice.update(status: 'paid')
              elsif @invoice.amount_paid > 0
                @invoice.update(status: 'partial')
              end
              
              # Send payment receipt email
              InvoiceMailer.payment_receipt(@invoice, payment).deliver_later
            end

            render json: {
              success: true,
              payment: payment_json(payment),
              invoice: invoice_json(@invoice.reload)
            }
          else
            # Payment failed
            error_message = zego_api.payment_error_message || 'Payment processing failed'
            payment.update(status: 'failed', notes: error_message)

            render json: {
              success: false,
              error: error_message,
              payment: payment_json(payment)
            }, status: :unprocessable_entity
          end
        else
          render json: {
            success: false,
            error: payment.errors.full_messages.join(', ')
          }, status: :unprocessable_entity
        end
      end

      # GET /api/portal/invoices/:id/download
      def download
        render json: { pdf_url: @invoice.pdf_url }
      end

      # GET /api/portal/invoices/stats
      def stats
        contact = current_portal_buyer.buyer
        
        unless contact
          render json: { error: 'Contact not found' }, status: :not_found
          return
        end

        invoices = contact.invoices.where(is_deleted: [false, nil])

        total_invoices = invoices.count
        total_amount = invoices.sum(:total)
        total_paid = invoices.sum(:amount_paid)
        total_due = invoices.sum(:amount_due)

        overdue_invoices = invoices.where('due_date < ? AND amount_due > 0', Date.today)
        overdue_count = overdue_invoices.count
        overdue_amount = overdue_invoices.sum(:amount_due)

        by_status = {
          draft: invoices.where(status: 'draft').count,
          sent: invoices.where(status: 'sent').count,
          partial: invoices.where(status: 'partial').count,
          paid: invoices.where(status: 'paid').count,
          overdue: overdue_count
        }

        render json: {
          total_invoices: total_invoices,
          total_amount: total_amount,
          total_paid: total_paid,
          total_due: total_due,
          overdue_count: overdue_count,
          overdue_amount: overdue_amount,
          by_status: by_status
        }
      end

      private

      def set_invoice
        contact = current_portal_buyer.buyer
        
        unless contact
          render json: { error: 'Contact not found' }, status: :not_found
          return
        end

        @invoice = contact.invoices.find_by(id: params[:id])

        unless @invoice
          render json: { error: 'Invoice not found' }, status: :not_found
          return
        end
      end

      def create_and_save_payment_method(data)
        contact = current_portal_buyer.buyer
        
        # Count existing payment methods to determine if this should be default
        existing_count = PaymentMethod.where(
          owner_type: 'Contact',
          owner_id: contact.id,
          is_deleted: [false, nil]
        ).count
        
        payment_method = PaymentMethod.new(
          owner: contact,
          method_type: data[:payment_type],
          company_id: contact.company_id,
          billing_first_name: data[:billing_first_name],
          billing_last_name: data[:billing_last_name],
          billing_street: data[:billing_street],
          billing_city: data[:billing_city],
          billing_state: data[:billing_state],
          billing_zip: data[:billing_zip],
          is_default: existing_count == 0
        )

        if data[:payment_type] == 'credit_card' || data[:payment_type] == 'debit_card'
          payment_method.credit_card_number = data[:credit_card_number]
          
          # Parse expiration date (format: "YYYY-MM-DD")
          if data[:credit_card_expires_on].present?
            begin
              exp_date = Date.parse(data[:credit_card_expires_on])
              payment_method.credit_card_exp_month = exp_date.month
              payment_method.credit_card_exp_year = exp_date.year
            rescue ArgumentError => e
              Rails.logger.error "Failed to parse credit card expiration date: #{e.message}"
            end
          end
          
          payment_method.credit_card_cvv = data[:credit_card_cvv]
          payment_method.is_debit_card = data[:is_debit_card] || false
        elsif data[:payment_type] == 'ach'
          payment_method.ach_routing_number = data[:ach_routing_number]
          payment_method.ach_account_number = data[:ach_account_number]
          payment_method.ach_account_type = data[:ach_account_type]
        end

        payment_method.save!
        payment_method
      end

      def invoice_json(invoice)
        deal = invoice.deal
        payment_type = deal&.payment_type
        {
          id: invoice.id,
          invoice_number: invoice.invoice_number,
          invoice_date: invoice.invoice_date,
          due_date: invoice.due_date,
          status: invoice.status,
          subtotal: invoice.subtotal,
          tax_amount: invoice.tax_amount,
          total: invoice.total,
          amount_paid: invoice.amount_paid,
          amount_due: invoice.amount_due,
          is_overdue: invoice.due_date && invoice.due_date < Date.today && invoice.amount_due > 0,
          days_overdue: invoice.due_date && invoice.due_date < Date.today ? (Date.today - invoice.due_date).to_i : 0,
          payment_type: payment_type,
          lender_name: deal&.lender_name,
          financed_amount: deal&.financed_amount,
          is_financed: %w[financed cash_and_finance].include?(payment_type.to_s),
          draw_schedule: invoice.draw_schedule
        }
      end

      def invoice_detail_json(invoice)
        deal = invoice.deal
        payment_type = deal&.payment_type
        invoice_json(invoice).merge(
          invoice_items: invoice.invoice_items.map { |item| invoice_item_json(item) },
          location: invoice.location ? {
            id: invoice.location_id,
            name: invoice.location.name
          } : nil,
          listing: invoice.listing ? {
            id: invoice.listing_id,
            name: invoice.listing.name || invoice.listing.title
          } : nil,
          contact: invoice.contact ? {
            id: invoice.contact_id,
            name: "#{invoice.contact.first_name} #{invoice.contact.last_name}",
            email: invoice.contact.email
          } : nil,
          notes: invoice.notes,
          payment_terms: invoice.terms,
          pdf_url: invoice.respond_to?(:pdf_url) ? invoice.pdf_url : nil,
          payment_type: payment_type,
          lender_name: deal&.lender_name,
          financed_amount: deal&.financed_amount,
          is_financed: %w[financed cash_and_finance].include?(payment_type.to_s),
          draw_schedule: invoice.draw_schedule
        )
      end

      def invoice_item_json(item)
        {
          id: item.id,
          description: item.description,
          quantity: item.quantity,
          rate: item.rate,
          amount: item.amount
        }
      end

      def payment_json(payment)
        {
          id: payment.id,
          amount: payment.amount,
          payment_date: payment.payment_date,
          payment_method: payment.payment_type,
          status: payment.status,
          external_id: payment.external_id,
          notes: payment.notes,
          processed_at: payment.processed_at
        }
      end
    end
  end
end

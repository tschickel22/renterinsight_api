# frozen_string_literal: true

module Api
  module Portal
    class LoansController < ApplicationController
      skip_before_action :authenticate
      before_action :authenticate_portal_buyer!
      before_action :set_loan, only: [:show, :payments, :make_payment]

      # GET /api/portal/loans
      def index
        contact = current_portal_buyer.buyer
        
        unless contact
          render json: { error: 'Contact not found' }, status: :not_found
          return
        end

        loans = contact.loans.where(is_deleted: [false, nil]).order(created_at: :desc)

        render json: loans.map { |loan| loan_json(loan) }
      end

      # GET /api/portal/loans/:id
      def show
        render json: loan_detail_json(@loan)
      end

      # GET /api/portal/loans/:id/payments
      def payments
        payments = @loan.payments.order(payment_date: :desc)
        render json: payments.map { |payment| payment_json(payment) }
      end

      # POST /api/portal/loans/:id/make_payment
      def make_payment
        amount = params[:amount].to_f
        payment_method_id = params[:payment_method_id]
        payment_method_data = params[:payment_method]
        allocation_method = params[:allocation_method] # 'principal' or 'advance'

        # Validate amount
        if amount <= 0
          render json: { success: false, error: 'Amount must be greater than 0' }, status: :unprocessable_entity
          return
        end

        if amount > @loan.current_balance
          render json: { success: false, error: 'Amount cannot exceed remaining balance' }, status: :unprocessable_entity
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

        # Create payment record
        payment = @loan.payments.build(
          amount: amount,
          payment_date: Date.today,
          payment_type: 'loan_payment',
          status: 'pending',
          company_id: @loan.company_id,
          payer: current_portal_buyer.buyer,
          payable: @loan,
          payment_method_id: payment_method.id,
          late_fee_amount: 0.0,
          gateway_name: 'zego'
        )

        if payment.save
          # Process payment via Zego
          zego_api = RenterInsightZegoApi.new(@loan.company)
          
          # Determine which Zego method to use
          if payment_method.external_id.present?
            success = zego_api.capture_payment(payment_method, payment, request)
          else
            success = zego_api.capture_portal_payment_with_save(payment_method, payment, request)
            
            if success
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
            transaction_id = zego_api.read_transaction_id
            
            # CRITICAL: Set this flag BEFORE updating status to prevent automatic loan.process_payment! callback
            # The Payment model has an after_commit callback that calls loan.process_payment! when status changes to 'completed'
            # We handle loan updates manually below with our new period tracking logic
            payment.define_singleton_method(:skip_loan_processing?) { true }
            
            payment.update(
              external_id: transaction_id,
              status: zego_api.payment_pending? ? 'pending' : 'completed',
              processed_at: Time.current
            )

            # If completed, update loan balance and handle allocation
            if payment.status == 'completed'
              # Calculate regular payment and current period requirements
              regular_payment = @loan.regular_payment_amount || 0
              late_fees_due = @loan.current_period_late_fees || 0
              total_due_for_period = regular_payment + late_fees_due
              
              # Calculate new period paid amount (don't update yet)
              new_period_paid = (@loan.current_period_paid || 0) + amount
              
              # Check if full period payment is now satisfied
              period_fully_paid = new_period_paid >= total_due_for_period
              
              # Prepare loan updates (will be done atomically)
              loan_updates = {
                total_paid: (@loan.total_paid || 0) + amount,
                current_balance: (@loan.current_balance || 0) - amount,
                current_period_paid: new_period_paid
              }
              
              # Handle payment allocation
              if allocation_method.present?
                # User explicitly chose allocation method
                if allocation_method == 'advance'
                  if @loan.next_payment_date.present? && regular_payment > 0
                    if period_fully_paid
                      # Calculate how many full periods this covers
                      payments_covered = (new_period_paid / regular_payment).floor
                      overflow = new_period_paid - (payments_covered * regular_payment)
                      
                      # Advance by calendar months
                      new_next_date = @loan.next_payment_date + payments_covered.months
                      loan_updates[:next_payment_date] = new_next_date
                      loan_updates[:current_period_paid] = overflow
                      loan_updates[:current_period_late_fees] = 0.0
                      
                      payment.update(
                        notes: "Portal payment - Advance payment covering #{payments_covered} payment(s). Next payment due: #{new_next_date.strftime('%m/%d/%Y')}"
                      )
                    else
                      # Partial payment
                      remaining_due = total_due_for_period - new_period_paid
                      payment.update(
                        notes: "Portal payment - Partial payment of $#{amount.round(2)} applied. $#{remaining_due.round(2)} still due on #{@loan.next_payment_date.strftime('%m/%d/%Y')}"
                      )
                    end
                  else
                    payment.update(
                      notes: "Portal payment - Advance payment of $#{amount.round(2)}"
                    )
                  end
                elsif allocation_method == 'principal'
                  # Principal reduction
                  if period_fully_paid
                    overflow_to_principal = new_period_paid - total_due_for_period
                    
                    if @loan.next_payment_date.present?
                      new_next_date = @loan.next_payment_date + 1.month
                      loan_updates[:next_payment_date] = new_next_date
                      loan_updates[:current_period_paid] = 0.0
                      loan_updates[:current_period_late_fees] = 0.0
                      
                      payment.update(
                        principal_amount: overflow_to_principal,
                        notes: "Portal payment - Full payment plus $#{overflow_to_principal.round(2)} extra to principal. Next payment due: #{new_next_date.strftime('%m/%d/%Y')}"
                      )
                    else
                      loan_updates[:current_period_paid] = 0.0
                      loan_updates[:current_period_late_fees] = 0.0
                      
                      payment.update(
                        principal_amount: overflow_to_principal,
                        notes: "Portal payment - Full payment plus $#{overflow_to_principal.round(2)} extra to principal"
                      )
                    end
                  else
                    # Partial payment
                    remaining_due = total_due_for_period - new_period_paid
                    payment.update(
                      principal_amount: amount,
                      notes: "Portal payment - $#{amount.round(2)} applied to principal. $#{remaining_due.round(2)} still due on #{@loan.next_payment_date&.strftime('%m/%d/%Y')}"
                    )
                  end
                end
              else
                # Regular payment (no allocation method)
                if @loan.next_payment_date.present?
                  if period_fully_paid
                    # Full period payment satisfied
                    overflow = new_period_paid - total_due_for_period
                    new_next_date = @loan.next_payment_date + 1.month
                    loan_updates[:next_payment_date] = new_next_date
                    loan_updates[:current_period_paid] = overflow
                    loan_updates[:current_period_late_fees] = 0.0
                    
                    payment.update(
                      notes: "Portal payment - Full payment applied. Next payment due: #{new_next_date.strftime('%m/%d/%Y')}"
                    )
                  else
                    # Partial payment
                    remaining_due = total_due_for_period - new_period_paid
                    payment.update(
                      notes: "Portal payment - Partial payment of $#{amount.round(2)} applied. $#{remaining_due.round(2)} still due on #{@loan.next_payment_date.strftime('%m/%d/%Y')}"
                    )
                  end
                else
                  payment.update(
                    notes: "Portal payment - $#{amount.round(2)} applied"
                  )
                end
              end
              
              # Execute all loan updates atomically
              @loan.update!(loan_updates)
            end

            render json: {
              success: true,
              payment: payment_json(payment),
              loan: loan_json(@loan.reload)
            }
          else
            error_message = zego_api.payment_error_message || 'Payment processing failed'
            payment.update(status: 'failed', notes: error_message)

            render json: {
              success: false,
              error: error_message,
              payment: payment_json(payment)
            }, status: :unprocessable_entity
          end
        else
          Rails.logger.error "Payment validation failed: #{payment.errors.full_messages.join(', ')}"
          render json: {
            success: false,
            error: payment.errors.full_messages.join(', ')
          }, status: :unprocessable_entity
        end
      end

      private

      def set_loan
        contact = current_portal_buyer.buyer
        
        unless contact
          render json: { error: 'Contact not found' }, status: :not_found
          return
        end

        @loan = contact.loans.find_by(id: params[:id])

        unless @loan
          render json: { error: 'Loan not found' }, status: :not_found
          return
        end
      end

      def create_and_save_payment_method(data)
        contact = current_portal_buyer.buyer
        
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

      def loan_json(loan)
        entity_description = if loan.financed_entity
          case loan.financed_entity_type
          when 'Unit'
            "#{loan.financed_entity.year} #{loan.financed_entity.make} #{loan.financed_entity.model}"
          when 'Property'
            loan.financed_entity.name
          else
            loan.financed_entity_type
          end
        else
          loan.loan_type.present? ? loan.loan_type.titleize + ' Loan' : "Loan #{loan.loan_number}"
        end

        # Calculate remaining amount due for current period
        regular_payment = loan.regular_payment_amount || 0
        late_fees_due = loan.current_period_late_fees || 0
        current_period_paid = loan.current_period_paid || 0
        remaining_amount_due = [regular_payment + late_fees_due - current_period_paid, 0].max

        {
          id: loan.id,
          loan_number: loan.loan_number,
          vehicle_info: entity_description,
          principal_amount: loan.principal_amount,
          interest_rate: loan.interest_rate,
          term_months: loan.term_months,
          monthly_payment: loan.regular_payment_amount,
          amount_paid: loan.total_paid || 0,
          remaining_balance: loan.current_balance,
          next_payment_date: loan.next_payment_date,
          next_payment_amount: remaining_amount_due,  # Dynamic remaining amount due
          payments_made: loan.payments_made || 0,
          payments_remaining: loan.payments_remaining || loan.term_months,
          start_date: loan.origination_date,
          maturity_date: loan.maturity_date,
          status: loan.status,
          is_current: loan.current_balance > 0 && loan.next_payment_date && loan.next_payment_date >= Date.today,
          days_past_due: loan.days_past_due || 0
        }
      end

      def loan_detail_json(loan)
        borrower_name = if loan.borrower.respond_to?(:full_name)
          loan.borrower.full_name
        elsif loan.borrower.respond_to?(:first_name) && loan.borrower.respond_to?(:last_name)
          "#{loan.borrower.first_name} #{loan.borrower.last_name}"
        else
          loan.borrower.try(:name) || 'Unknown'
        end

        borrower_email = loan.borrower.respond_to?(:email) ? loan.borrower.email : nil

        loan_json(loan).merge(
          borrower: {
            id: loan.borrower_id,
            type: loan.borrower_type,
            name: borrower_name,
            email: borrower_email
          },
          payment_summary: {
            last_payment_date: last_payment_date(loan),
            last_payment_amount: last_payment_amount(loan)
          }
        )
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

      def payments_made_count(loan)
        loan.payments.where(status: 'completed').count
      end

      def last_payment_date(loan)
        loan.payments.where(status: 'completed').maximum(:payment_date)
      end

      def last_payment_amount(loan)
        last_payment = loan.payments.where(status: 'completed').order(payment_date: :desc).first
        last_payment&.amount
      end
    end
  end
end

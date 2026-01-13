# frozen_string_literal: true

require 'csv'

module Api
  module V1
    class PaymentsController < ApplicationController
      before_action :set_company_scope
      before_action :set_payment, only: %i[show update destroy cancel refund void]

      # GET /api/v1/payments
      def index
        return unless authorize_action!('finance', 'read')
        
        # STRICT TENANT ISOLATION: Only show payments from current company
        # RBAC: Location-tier users only see their assigned locations
        @payments = if current_user.uses_rbac?
          if current_user.effective_admin?
            @company.payments.where(is_deleted: [false, nil])
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              @company.payments.where(is_deleted: [false, nil])
                              .where(location_id: location_ids)
            else
              @company.payments.where(is_deleted: [false, nil])
            end
          end
        else
          @company.payments.where(is_deleted: [false, nil])
        end
        
        # Apply location selector filter (if user selected a specific location)
        @payments = @payments.for_current_location
        
        # Include associations for better response
        @payments = @payments.includes(:payment_method, :payer, :loan, :location)
        
        # Apply filters
        @payments = @payments.by_status(params[:status]) if params[:status].present?
        @payments = @payments.by_type(params[:payment_type]) if params[:payment_type].present?
        @payments = @payments.by_gateway(params[:gateway_name]) if params[:gateway_name].present?
        
        # Date range filters
        if params[:start_date].present? && params[:end_date].present?
          start_date = Date.parse(params[:start_date])
          end_date = Date.parse(params[:end_date])
          @payments = @payments.by_date(start_date, end_date)
        end
        
        # Filter by payer
        if params[:payer_type].present? && params[:payer_id].present?
          @payments = @payments.where(payer_type: params[:payer_type], payer_id: params[:payer_id])
        end
        
        # Filter by loan
        @payments = @payments.where(loan_id: params[:loan_id]) if params[:loan_id].present?
        
        # Simple pagination without kaminari gem
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 25).to_i
        offset = (page - 1) * per_page
        
        total_count = @payments.count
        @payments = @payments.order(created_at: :desc).limit(per_page).offset(offset)
        
        render json: {
          payments: @payments.as_json(
            include: {
              payment_method: { only: [:id, :method_type, :display_name] },
              payer: { only: [:id, :type, :name, :email] },
              loan: { only: [:id, :loan_number, :current_balance] },
              location: { only: [:id, :name] }
            },
            methods: [:display_name, :payer_name, :breakdown, :fee_description]
          ),
          meta: {
            current_page: page,
            total_pages: (total_count.to_f / per_page).ceil,
            total_count: total_count
          }
        }
      end

      # GET /api/v1/payments/:id
      def show
        return unless authorize_action!('finance', 'read')
        
        render json: @payment.as_json(
          include: {
            payment_method: { only: [:id, :method_type, :display_name, :masked_account_number] },
            payer: { only: [:id, :type, :name, :email, :phone] },
            loan: { 
              only: [:id, :loan_number, :amount, :current_balance, :total_paid],
              methods: [:payment_schedule]
            },
            location: { only: [:id, :name, :address] }
          },
          methods: [:display_name, :payer_name, :breakdown, :fee_description, :can_refund?, :can_void?]
        )
      end

      # GET /api/v1/payments/stats
      def stats
        return unless authorize_action!('finance', 'read')
        
        # STRICT TENANT ISOLATION: Only stats for current company
        base_payments = @company.payments.where(is_deleted: [false, nil])
        
        # Apply strict location filter - only payments explicitly assigned to selected location
        if Current.location_filtered?
          base_payments = base_payments.where(location_id: Current.location_id)
        end
        
        # Calculate statistics
        total_payments = base_payments.count
        completed_payments = base_payments.completed.count
        pending_payments = base_payments.pending.count
        failed_payments = base_payments.failed.count
        refunded_payments = base_payments.refunded.count
        
        # Financial stats
        total_collected = base_payments.completed.sum(:amount)
        pending_amount = base_payments.pending.sum(:amount)
        refunded_amount = base_payments.refunded.sum(:refund_amount)
        
        # Processing fees
        total_fees_collected = base_payments.completed.sum(:processing_fee)
        
        # Recent stats (last 30 days)
        recent_payments = base_payments.where('created_at >= ?', 30.days.ago)
        recent_collected = recent_payments.completed.sum(:amount)
        recent_count = recent_payments.completed.count
        
        # By payment type
        by_type = base_payments.group(:payment_type).count
        
        # By status
        by_status = {
          pending: pending_payments,
          completed: completed_payments,
          failed: failed_payments,
          refunded: refunded_payments,
          processing: base_payments.processing.count
        }
        
        render json: {
          total_payments: total_payments,
          total_collected: total_collected.to_f.round(2),
          pending_amount: pending_amount.to_f.round(2),
          refunded_amount: refunded_amount.to_f.round(2),
          total_fees_collected: total_fees_collected.to_f.round(2),
          by_status: by_status,
          by_type: by_type,
          recent_30_days: {
            count: recent_count,
            amount: recent_collected.to_f.round(2)
          },
          average_payment: completed_payments > 0 ? (total_collected / completed_payments).to_f.round(2) : 0
        }
      end

      # POST /api/v1/payments
      def create
        return unless authorize_action!('finance', 'create')
        
        # STRICT TENANT ISOLATION: Create payment within current company
        @payment = @company.payments.new(payment_params)
        
        # Auto-assign location from selector (if user selected a specific location)
        @payment.location_id ||= Current.location_id if Current.location_id.present?
        
        # RBAC fallback: Location-tier users auto-assign to their first location if no selector
        if @payment.location_id.nil? && current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          @payment.location_id ||= location_ids.first if location_ids.any?
        end
        
        # Convert contact_id/account_id to polymorphic payer_type/payer_id
        if params[:contact_id].present?
          @payment.payer_type = 'Contact'
          @payment.payer_id = params[:contact_id]
        elsif params[:account_id].present?
          @payment.payer_type = 'Account'
          @payment.payer_id = params[:account_id]
        end
        
        # Set gateway name
        @payment.gateway_name ||= 'zego'
        
        # Save payment first (to get ID and payment_number)
        if @payment.save
          # Process payment immediately if not scheduled
          if @payment.scheduled_at.blank? || @payment.scheduled_at <= Time.current
            process_payment_now(@payment)
          else
            # Payment is scheduled for future - leave as pending
            Rails.logger.info "[Payments] Scheduled payment #{@payment.id} for #{@payment.scheduled_at}"
            
            render json: {
              message: "Payment scheduled for #{@payment.scheduled_at.strftime('%Y-%m-%d %H:%M')}",
              payment: @payment.as_json(
                include: {
                  payment_method: { only: [:id, :method_type, :display_name] },
                  payer: { only: [:id, :type, :name, :email] },
                  location: { only: [:id, :name] }
                },
                methods: [:display_name, :payer_name, :breakdown]
              )
            }, status: :created
          end
        else
          render json: { errors: @payment.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/payments/:id
      def update
        return unless authorize_action!('finance', 'update')
        
        # Only allow updates for manual payments (no external_id)
        if @payment.external_id.present?
          render json: { error: 'Cannot edit payments processed through a gateway' }, status: :unprocessable_entity
          return
        end
        
        if @payment.update(update_payment_params)
          Rails.logger.info "[Payments] Updated payment #{@payment.id}"
          
          render json: {
            message: 'Payment updated successfully',
            payment: @payment.as_json(
              include: {
                payment_method: { only: [:id, :method_type, :display_name] },
                payer: { only: [:id, :type, :name, :email] },
                location: { only: [:id, :name] }
              },
              methods: [:display_name, :payer_name, :breakdown]
            )
          }
        else
          render json: { errors: @payment.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/payments/:id
      def destroy
        return unless authorize_action!('finance', 'delete')
        
        # Only allow deletion for manual payments (no external_id)
        if @payment.external_id.present?
          render json: { error: 'Cannot delete payments processed through a gateway' }, status: :unprocessable_entity
          return
        end
        
        if @payment.soft_delete!
          Rails.logger.info "[Payments] Deleted payment #{@payment.id}"
          
          render json: {
            message: 'Payment deleted successfully'
          }
        else
          render json: { error: 'Failed to delete payment' }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/payments/:id/cancel
      def cancel
        return unless authorize_action!('finance', 'delete')
        
        unless @payment.pending?
          render json: { error: 'Only pending payments can be cancelled' }, status: :unprocessable_entity
          return
        end
        
        if @payment.cancel!
          Rails.logger.info "[Payments] Cancelled payment #{@payment.id}"
          
          render json: {
            message: 'Payment cancelled successfully',
            payment: @payment.as_json(
              include: {
                payment_method: { only: [:id, :method_type, :display_name] },
                payer: { only: [:id, :type, :name, :email] }
              },
              methods: [:display_name, :payer_name]
            )
          }
        else
          render json: { error: 'Failed to cancel payment' }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/payments/:id/refund
      def refund
        return unless authorize_action!('finance', 'update')
        
        unless @payment.can_refund?
          render json: { error: 'This payment cannot be refunded' }, status: :unprocessable_entity
          return
        end
        
        begin
          # Process refund through Zego API
          api = ZegoPaymentApi.new(@company)
          
          refund_amount = params[:amount]&.to_f || @payment.amount
          refund_reason = params[:reason]
          
          if api.refund_transaction(@payment, request)
            # Mark payment as refunded
            if @payment.process_refund!(amount: refund_amount, reason: refund_reason)
              Rails.logger.info "[Payments] Refunded payment #{@payment.id}: $#{refund_amount}"
              
              render json: {
                message: 'Payment refunded successfully',
                payment: @payment.as_json(
                  include: {
                    payment_method: { only: [:id, :method_type, :display_name] },
                    payer: { only: [:id, :type, :name, :email] }
                  },
                  methods: [:display_name, :payer_name, :breakdown]
                )
              }
            else
              render json: { error: 'Failed to update payment status after refund' }, status: :unprocessable_entity
            end
          else
            error_message = api.payment_error_message
            Rails.logger.error "[Payments] Zego refund failed: #{error_message}"
            render json: { error: "Refund failed: #{error_message}" }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "[Payments] Exception during refund: #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          
          render json: { error: "Refund failed: #{e.message}" }, status: :unprocessable_entity
        end
      end

      # POST /api/v1/payments/:id/void
      def void
        return unless authorize_action!('finance', 'update')
        
        unless @payment.can_void?
          render json: { error: 'This payment cannot be voided' }, status: :unprocessable_entity
          return
        end
        
        begin
          # Void transaction through Zego API
          api = ZegoPaymentApi.new(@company)
          
          if api.void_transaction(@payment, request)
            # Mark payment as voided
            if @payment.void!
              Rails.logger.info "[Payments] Voided payment #{@payment.id}"
              
              render json: {
                message: 'Payment voided successfully',
                payment: @payment.as_json(
                  include: {
                    payment_method: { only: [:id, :method_type, :display_name] },
                    payer: { only: [:id, :type, :name, :email] }
                  },
                  methods: [:display_name, :payer_name]
                )
              }
            else
              render json: { error: 'Failed to update payment status after void' }, status: :unprocessable_entity
            end
          else
            error_message = api.payment_error_message
            Rails.logger.error "[Payments] Zego void failed: #{error_message}"
            render json: { error: "Void failed: #{error_message}" }, status: :unprocessable_entity
          end
        rescue => e
          Rails.logger.error "[Payments] Exception during void: #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          
          render json: { error: "Void failed: #{e.message}" }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/payments/export
      def export
        return unless authorize_action!('finance', 'export')
        
        # Use same filtering logic as index
        @payments = if current_user.uses_rbac?
          if current_user.effective_admin?
            @company.payments.where(is_deleted: [false, nil])
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              @company.payments.where(is_deleted: [false, nil])
                              .where(location_id: location_ids)
            else
              @company.payments.where(is_deleted: [false, nil])
            end
          end
        else
          @company.payments.where(is_deleted: [false, nil])
        end
        
        # Apply location selector filter
        @payments = @payments.for_current_location
        
        # Include associations
        @payments = @payments.includes(:payment_method, :payer, :loan, :location)
        
        # Apply same filters as index
        @payments = @payments.by_status(params[:status]) if params[:status].present?
        @payments = @payments.by_type(params[:payment_type]) if params[:payment_type].present?
        
        if params[:start_date].present? && params[:end_date].present?
          start_date = Date.parse(params[:start_date])
          end_date = Date.parse(params[:end_date])
          @payments = @payments.by_date(start_date, end_date)
        end
        
        # Generate CSV
        csv_data = CSV.generate(headers: true) do |csv|
          csv << [
            'Payment Number', 'Date', 'Status', 'Type', 'Payer', 
            'Payment Method', 'Amount', 'Processing Fee', 'Total Charged',
            'Loan Number', 'Location', 'External ID', 'Created At'
          ]
          
          @payments.order(created_at: :desc).find_each do |payment|
            csv << [
              payment.payment_number,
              payment.payment_date&.strftime('%Y-%m-%d'),
              payment.status.titleize,
              payment.payment_type.titleize,
              payment.payer_name,
              payment.payment_method.display_name,
              payment.amount.to_f.round(2),
              payment.processing_fee.to_f.round(2),
              payment.total_charged.to_f.round(2),
              payment.loan&.loan_number,
              payment.location&.name,
              payment.external_id,
              payment.created_at.strftime('%Y-%m-%d %H:%M')
            ]
          end
        end
        
        send_data csv_data, 
          filename: "payments_#{Date.current}.csv", 
          type: 'text/csv',
          disposition: 'attachment'
      end

      private

      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [PaymentsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        # Use current_company_id which respects X-Company-ID header for platform admins
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [PaymentsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [PaymentsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [PaymentsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end

      def set_payment
        # STRICT TENANT ISOLATION: Only access payments in same company
        # RBAC: Location-tier users only access their assigned locations
        @payment = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            @company.payments.where(location_id: location_ids).find(params[:id])
          else
            @company.payments.find(params[:id])
          end
        else
          @company.payments.find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Payment not found or access denied' }, status: :not_found
        return
      end

      # Process payment immediately through Zego API
      def process_payment_now(payment)
        begin
          payment.update!(status: 'processing')
          
          api = ZegoPaymentApi.new(@company)
          
          # Capture payment through Zego
          if api.capture_payment(payment.payment_method, payment, request)
            # Store transaction details
            external_id = api.read_transaction_id
            
            # Mark as completed
            payment.mark_completed!(external_id: external_id)
            
            # Notify payment success
            if payment.payer_type == 'Contact' && payment.payer_id.present?
              contact = Contact.find_by(id: payment.payer_id)
              if contact && contact.user_id.present?
                owner = User.find_by(id: contact.user_id)
                if owner
                  trigger_notification(
                    :payment_received,
                    recipient: owner,
                    notifiable: payment,
                    message: "Payment of $#{payment.amount} received from #{contact.full_name}."
                  )
                end
              end
            end
            
            Rails.logger.info "[Payments] Successfully processed payment #{payment.id}: $#{payment.amount}"
            
            render json: {
              message: 'Payment processed successfully',
              payment: payment.as_json(
                include: {
                  payment_method: { only: [:id, :method_type, :display_name] },
                  payer: { only: [:id, :type, :name, :email] },
                  loan: { only: [:id, :loan_number, :current_balance] },
                  location: { only: [:id, :name] }
                },
                methods: [:display_name, :payer_name, :breakdown]
              )
            }, status: :created
          else
            # Payment failed
            error_message = api.payment_error_message
            payment.mark_failed!(error_message)
            
            # Notify payment failure
            if payment.payer_type == 'Contact' && payment.payer_id.present?
              contact = Contact.find_by(id: payment.payer_id)
              if contact && contact.user_id.present?
                owner = User.find_by(id: contact.user_id)
                if owner
                  trigger_notification(
                    :payment_failed,
                    recipient: owner,
                    notifiable: payment,
                    message: "Payment of $#{payment.amount} from #{contact.full_name} failed: #{error_message}"
                  )
                end
              end
            end
            
            Rails.logger.error "[Payments] Payment processing failed: #{error_message}"
            
            render json: { 
              error: "Payment failed: #{error_message}",
              payment: payment.as_json(only: [:id, :payment_number, :status, :failure_reason])
            }, status: :unprocessable_entity
          end
        rescue => e
          # Exception during processing
          payment.mark_failed!(e.message) if payment.persisted?
          
          Rails.logger.error "[Payments] Exception during payment processing: #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          
          render json: { error: "Payment processing failed: #{e.message}" }, status: :unprocessable_entity
        end
      end

      def update_payment_params
        params.require(:payment).permit(
          :amount,
          :payment_at,
          :notes,
          :description
        )
      end

      def payment_params
        # Support both wrapped { payment: {...} } and unwrapped params
        raw = params[:payment].present? ? params[:payment].to_unsafe_h : params.to_unsafe_h
        
        # Build clean params with snake_case only
        clean = {}
        
        # Direct mappings
        %w[payment_type amount payment_method_id payer_type payer_id loan_id
           scheduled_at description fee_responsibility processing_fee
           principal_amount interest_amount fee_amount late_fee_amount].each do |key|
          clean[key] = raw[key] if raw.key?(key)
        end
        
        # Handle camelCase variants
        clean['payment_type'] ||= raw['paymentType']
        clean['payment_method_id'] ||= raw['paymentMethodId']
        clean['payer_type'] ||= raw['payerType']
        clean['payer_id'] ||= raw['payerId']
        clean['loan_id'] ||= raw['loanId']
        clean['scheduled_at'] ||= raw['scheduledAt']
        clean['fee_responsibility'] ||= raw['feeResponsibility']
        clean['processing_fee'] ||= raw['processingFee']
        clean['principal_amount'] ||= raw['principalAmount']
        clean['interest_amount'] ||= raw['interestAmount']
        clean['fee_amount'] ||= raw['feeAmount']
        clean['late_fee_amount'] ||= raw['lateFeeAmount']
        
        # Remove nil/blank values and return permitted params
        clean.compact.reject { |_, v| v.blank? }
      end
    end
  end
end

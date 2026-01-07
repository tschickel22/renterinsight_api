# frozen_string_literal: true

module Api
  module V1
    class CommissionPaymentsController < ApplicationController
      before_action :set_company_scope
      before_action :set_payment, only: [:show, :update, :destroy, :approve, :mark_paid, :reverse]
      
      # GET /api/v1/commission-payments
      # GET /api/v1/deals/:deal_id/commissions
      def index
        return unless authorize_action!('commission_payments', 'read')
        
        payments = @company.commission_payments.active
        
        # Filter by deal if nested route
        if params[:deal_id].present?
          payments = payments.where(deal_id: params[:deal_id])
        end
        
        # Filter by status
        if params[:status].present?
          payments = payments.where(status: params[:status])
        end
        
        # Filter by payee
        if params[:payee_user_id].present?
          payments = payments.for_payee(params[:payee_user_id])
        end
        
        # Filter by location
        if params[:location_id].present?
          payments = payments.where(location_id: params[:location_id])
        end
        
        # Filter by date range
        if params[:start_date].present? && params[:end_date].present?
          start_date = Date.parse(params[:start_date])
          end_date = Date.parse(params[:end_date])
          payments = payments.where('created_at >= ? AND created_at <= ?', start_date, end_date)
        end
        
        # Apply location selector filter
        payments = payments.for_current_location if Current.location_filtered?
        
        # Apply RBAC filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          payments = location_ids.any? ? 
            payments.where(location_id: location_ids) : 
            payments.none
        end
        
        # Order by date
        payments = payments.ordered
        
        render json: {
          payments: payments.map { |p| payment_json(p) },
          meta: {
            total: payments.count,
            total_amount: payments.sum(:amount).round(2)
          }
        }
      end
      
      # GET /api/v1/commission-payments/stats
      def stats
        return unless authorize_action!('commission_payments', 'read')
        
        base_payments = @company.commission_payments.active
        base_payments = base_payments.for_current_location if Current.location_filtered?
        
        # Apply RBAC filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          base_payments = location_ids.any? ? 
            base_payments.where(location_id: location_ids) : 
            base_payments.none
        end
        
        render json: {
          pending: {
            count: base_payments.pending.count,
            amount: base_payments.pending.sum(:amount).round(2)
          },
          approved: {
            count: base_payments.approved.count,
            amount: base_payments.approved.sum(:amount).round(2)
          },
          paid: {
            count: base_payments.paid.count,
            amount: base_payments.paid.sum(:amount).round(2)
          },
          total: {
            count: base_payments.count,
            amount: base_payments.sum(:amount).round(2)
          },
          this_month: {
            count: base_payments.where('created_at >= ?', Date.today.beginning_of_month).count,
            amount: base_payments.where('created_at >= ?', Date.today.beginning_of_month).sum(:amount).round(2)
          }
        }
      end
      
      # GET /api/v1/commission-payments/:id
      def show
        return unless authorize_action!('commission_payments', 'read')
        
        render json: { payment: payment_json(@payment, detailed: true) }
      end
      
      # POST /api/v1/commission-payments
      def create
        return unless authorize_action!('commission_payments', 'create')
        
        payment = @company.commission_payments.build(payment_params)
        
        # Auto-assign location_id if filtered
        payment.location_id ||= Current.location_id if Current.location_id.present?
        
        if payment.save
          render json: { payment: payment_json(payment, detailed: true) }, status: :created
        else
          render json: { errors: payment.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH /api/v1/commission-payments/:id
      def update
        return unless authorize_action!('commission_payments', 'update')
        
        if @payment.update(payment_params)
          render json: { payment: payment_json(@payment, detailed: true) }
        else
          render json: { errors: @payment.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/commission-payments/:id
      def destroy
        return unless authorize_action!('commission_payments', 'delete')
        
        @payment.update!(is_deleted: true, deleted_at: Time.current)
        head :no_content
      end
      
      # POST /api/v1/commission-payments/:id/approve
      def approve
        return unless authorize_action!('commission_payments', 'approve')
        
        if @payment.approve!(approved_by: current_user)
          render json: { payment: payment_json(@payment, detailed: true) }
        else
          render json: { error: 'Cannot approve payment' }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/commission-payments/:id/mark-paid
      def mark_paid
        return unless authorize_action!('commission_payments', 'mark_paid')
        
        unless params[:payment_method].present?
          render json: { error: 'payment_method is required' }, status: :bad_request
          return
        end
        
        if @payment.mark_paid!(
          paid_by: current_user,
          payment_method: params[:payment_method],
          payment_reference: params[:payment_reference]
        )
          render json: { payment: payment_json(@payment, detailed: true) }
        else
          render json: { error: 'Cannot mark payment as paid' }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/commission-payments/:id/reverse
      def reverse
        return unless authorize_action!('commission_payments', 'reverse')
        
        unless params[:reason].present?
          render json: { error: 'reason is required' }, status: :bad_request
          return
        end
        
        if @payment.reverse!(reversed_by: current_user, reason: params[:reason])
          render json: { payment: payment_json(@payment, detailed: true) }
        else
          render json: { error: 'Cannot reverse payment' }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/commission-payments/bulk-approve
      def bulk_approve
        return unless authorize_action!('commission_payments', 'approve')
        
        payment_ids = params[:payment_ids] || []
        
        if payment_ids.empty?
          render json: { error: 'payment_ids required' }, status: :bad_request
          return
        end
        
        payments = @company.commission_payments.where(id: payment_ids, status: 'pending')
        
        approved_count = 0
        errors = []
        
        payments.each do |payment|
          if payment.approve!(approved_by: current_user)
            approved_count += 1
          else
            errors << "Payment #{payment.payment_number}: #{payment.errors.full_messages.join(', ')}"
          end
        end
        
        render json: {
          approved_count: approved_count,
          errors: errors
        }
      end
      
      # POST /api/v1/commission-payments/bulk-mark-paid
      def bulk_mark_paid
        return unless authorize_action!('commission_payments', 'mark_paid')
        
        payment_ids = params[:payment_ids] || []
        payment_method = params[:payment_method]
        payment_reference = params[:payment_reference]
        
        if payment_ids.empty? || payment_method.blank?
          render json: { error: 'payment_ids and payment_method required' }, status: :bad_request
          return
        end
        
        payments = @company.commission_payments.where(id: payment_ids, status: 'approved')
        
        paid_count = 0
        errors = []
        
        payments.each do |payment|
          if payment.mark_paid!(paid_by: current_user, payment_method: payment_method, payment_reference: payment_reference)
            paid_count += 1
          else
            errors << "Payment #{payment.payment_number}: #{payment.errors.full_messages.join(', ')}"
          end
        end
        
        render json: {
          paid_count: paid_count,
          errors: errors
        }
      end
      
      # POST /api/v1/commission-payments/generate-for-deal
      def generate_for_deal
        return unless authorize_action!('commission_payments', 'create')
        
        deal_id = params[:deal_id]
        
        unless deal_id.present?
          render json: { error: 'deal_id required' }, status: :bad_request
          return
        end
        
        deal = @company.deals.find(deal_id)
        payment = CommissionPaymentGeneratorService.generate_for_deal(deal)
        
        if payment.present?
          render json: { payment: payment_json(payment, detailed: true) }, status: :created
        else
          render json: { error: 'Could not generate payment (deal not delivered or payment already exists)' }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found' }, status: :not_found
      end
      
      # GET /api/v1/commission-payments/preview-for-deal/:deal_id
      # POST /api/v1/deals/:deal_id/commissions/preview
      def preview_for_deal
        return unless authorize_action!('commission_payments', 'read')
        
        deal_id = params[:deal_id]
        
        unless deal_id.present?
          render json: { error: 'deal_id required' }, status: :bad_request
          return
        end
        
        deal = @company.deals.find(deal_id)
        preview = CommissionPaymentGeneratorService.preview_for_deal(deal)
        
        render json: preview
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found' }, status: :not_found
      end
      
      # Alias for nested route
      alias_method :preview, :preview_for_deal
      
      private
      
      def set_payment
        @payment = @company.commission_payments.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Payment not found' }, status: :not_found
      end
      
      def payment_params
        params.require(:payment).permit(
          :deal_id,
          :payee_user_id,
          :amount,
          :status,
          :notes,
          :payment_method,
          :payment_reference,
          :location_id
        )
      end
      
      def payment_json(payment, detailed: false)
        base = {
          id: payment.id,
          paymentNumber: payment.payment_number,
          status: payment.status,
          displayStatus: payment.display_status,
          amount: payment.amount,
          
          # Relationships
          dealId: payment.deal_id,
          dealName: payment.deal&.name,
          payeeUserId: payment.payee_user_id,
          payeeName: payment.payee_user&.name,
          locationId: payment.location_id,
          locationName: payment.location&.name,
          
          # Workflow
          approvedAt: payment.approved_at&.iso8601,
          approvedBy: payment.approved_by_user&.name,
          paidAt: payment.paid_at&.iso8601,
          paidBy: payment.paid_by_user&.name,
          paymentMethod: payment.payment_method,
          paymentReference: payment.payment_reference,
          
          # Reversal
          isReversed: payment.is_reversed,
          reversedAt: payment.reversed_at&.iso8601,
          reversedBy: payment.reversed_by_user&.name,
          reversalReason: payment.reversal_reason,
          
          # Status checks
          canApprove: payment.can_approve?,
          canMarkPaid: payment.can_mark_paid?,
          canReverse: payment.can_reverse?,
          
          createdAt: payment.created_at&.iso8601,
          updatedAt: payment.updated_at&.iso8601
        }
        
        if detailed
          base[:notes] = payment.notes
          base[:calculationDetails] = payment.calculation_details
          base[:lineItems] = payment.line_items
          base[:dealEconomics] = payment.deal_economics
        end
        
        base
      end
    end
  end
end

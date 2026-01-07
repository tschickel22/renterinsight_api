# frozen_string_literal: true

module Api
  module Crm
    class CommissionPaymentsController < ApplicationController
      before_action :set_company_scope
      before_action :set_deal
      
      # GET /api/crm/deals/:deal_id/commissions
      def index
        return unless authorize_action!('commissions', 'read')
        
        payments = @company.commission_payments.active.where(deal_id: @deal.id)
        
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
          payments: payments.map { |p| payment_json(p, detailed: true) },
          meta: {
            total: payments.count,
            total_amount: payments.sum(:amount).round(2)
          }
        }
      end
      
      # POST /api/crm/deals/:deal_id/commissions/preview
      def preview
        return unless authorize_action!('commissions', 'read')
        
        preview_data = CommissionPaymentGeneratorService.preview_for_deal(@deal)
        
        render json: preview_data
      end
      
      private
      
      def set_deal
        @deal = @company.deals.find(params[:deal_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found' }, status: :not_found
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

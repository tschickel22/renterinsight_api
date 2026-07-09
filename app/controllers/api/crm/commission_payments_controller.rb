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
        
        # Get commission plan - either from deal or auto-determine
        plan = @deal.commission_plan || @deal.determine_commission_plan
        
        # Check if deal is delivered
        is_delivered = @deal.stage_is_won? && @deal.delivery_date.present?
        
        # Determine salesperson
        salesperson = @deal.primary_salesperson || @deal.owner
        
        unless salesperson
          return render json: {
            canGenerate: false,
            message: 'No salesperson assigned to deal',
            salespersonName: nil,
            planName: nil,
            totalAmount: 0,
            lineItems: [],
            isDelivered: is_delivered
          }
        end
        
        unless plan
          return render json: {
            canGenerate: false,
            message: 'No commission plan available for this salesperson',
            salespersonName: salesperson.name,
            planName: nil,
            totalAmount: 0,
            lineItems: [],
            isDelivered: is_delivered
          }
        end
        
        # Calculate commission preview
        line_items = []
        total_amount = 0
        
        plan.active_components.each do |component|
          # Calculate basis amount based on component type and gross type
          basis_amount = 0
          
          case component.component_type
          when 'percent_of_gross'
            # Use gross_type to determine which gross to use
            basis_amount = case component.gross_type
            when 'front'
              @deal.front_gross
            when 'back'
              @deal.back_gross
            when 'total'
              @deal.total_gross
            when 'commissionable_front'
              @deal.commissionable_front_gross
            when 'addon'
              @deal.addon_gross
            else
              0
            end
          when 'flat_per_unit'
            basis_amount = @deal.quantity || 1
          when 'volume_bonus'
            # For volume bonus, basis is 1 if threshold met, 0 otherwise
            # This is simplified - would need to check actual units sold in period
            basis_amount = 1
          when 'addon_commission'
            basis_amount = @deal.addon_gross
          end
          
          # Calculate commission amount based on component type
          calculated_amount = case component.component_type
          when 'percent_of_gross'
            (basis_amount * component.rate).round(2)
          when 'flat_per_unit'
            (component.flat_amount * basis_amount).round(2)
          when 'volume_bonus'
            # Simplified: always include bonus (would check threshold in real calculation)
            component.flat_amount
          when 'addon_commission'
            (basis_amount * component.rate).round(2)
          else
            0
          end
          
          line_items << {
            componentName: component.name,
            calculationMethod: component.component_type,
            calculationBasis: component.gross_type || component.component_type,
            basisAmount: basis_amount,
            rate: component.rate || component.flat_amount,
            calculatedAmount: calculated_amount
          }
          
          total_amount += calculated_amount
        end
        
        render json: {
          canGenerate: is_delivered && total_amount > 0,
          message: is_delivered ? nil : 'Deal must be closed won with delivery date',
          salespersonName: salesperson.name,
          planName: plan.name,
          totalAmount: total_amount.round(2),
          lineItems: line_items,
          isDelivered: is_delivered,
          dealEconomics: {
            sellingPrice: @deal.selling_price || 0,
            frontGross: @deal.front_gross,
            backGross: @deal.back_gross,
            totalGross: @deal.total_gross
          }
        }
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

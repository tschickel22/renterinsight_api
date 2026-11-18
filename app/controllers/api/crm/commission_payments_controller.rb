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
      # What each person on the deal would earn, from the engine that makes the
      # payments. The deal card sends the plan and people chosen on screen before
      # they are saved; nothing here is written.
      def preview
        return unless authorize_action!('commissions', 'read')
        return unless apply_choices_on_screen

        @deal.commission_plan ||= @deal.determine_commission_plan
        result = CommissionPaymentGeneratorService.preview_for_deal(@deal)
        render json: preview_json(result)
      end

      # POST /api/crm/deals/:deal_id/commissions/refresh
      # Makes the payments for a deal that is ready, or brings unpaid ones up to
      # date after the deal changed. What is already paid stands.
      def refresh
        return unless authorize_action!('commission_payments', 'create')

        unless @deal.commissions_payable?
          return render json: { error: CommissionSettings.not_payable_message(@company) }, status: :unprocessable_entity
        end

        CommissionPaymentGeneratorService.new(@deal).recalculate
        payments = @company.commission_payments.active.where(deal_id: @deal.id).ordered
        render json: { payments: payments.map { |p| payment_json(p, detailed: true) } }
      end

      private
      
      def set_deal
        @deal = @company.deals.find(params[:deal_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found' }, status: :not_found
      end
      
      PREVIEW_PEOPLE = {
        owner_id: :primary_salesperson_id, secondary_salesperson_id: :secondary_salesperson_id,
        sales_manager_id: :sales_manager_id, finance_manager_id: :finance_manager_id, desk_manager_id: :desk_manager_id
      }.freeze

      # Sets the on-screen choices on this in-memory deal only. False after
      # rendering an error when a choice is not from this company.
      def apply_choices_on_screen
        @deal.readonly!
        if params.key?(:commission_plan_id) && !payments_locked?
          plan = params[:commission_plan_id].presence && @company.commission_plans.find_by(id: params[:commission_plan_id])
          if params[:commission_plan_id].present? && plan.nil?
            render json: { error: 'Commission plan not found' }, status: :not_found
            return false
          end
          @deal.commission_plan = plan
        end

        PREVIEW_PEOPLE.each do |param, field|
          next unless params.key?(param)

          user_id = params[param].presence&.to_i
          if user_id && !@company.users.exists?(id: user_id)
            render json: { error: 'That person is not on this account' }, status: :unprocessable_entity
            return false
          end
          @deal.public_send("#{field}=", user_id)
        end
        true
      end

      def payments_locked?
        @company.commission_payments.active.where(deal_id: @deal.id).where.not(status: %w[reversed cancelled]).exists?
      end

      def available_plans
        plans = @company.commission_plans.active.current.where(location_id: [nil, @deal.location_id]).order(:display_order, :name).to_a
        plans |= [@deal.commission_plan] if @deal.commission_plan
        plans.map { |p| { id: p.id, name: p.name, isActive: p.is_active && p.valid_for_date? } }
      end

      def preview_json(result)
        plan = @deal.commission_plan
        {
          planId: plan&.id,
          planName: plan&.name,
          planActive: plan ? (plan.is_active && plan.valid_for_date?) : false,
          availablePlans: available_plans,
          locked: payments_locked?,
          costEntered: @deal.cost_entered?,
          commissionableGross: @deal.commission_gross('commissionable_front')&.to_f,
          totalCommission: result[:total_commission].to_f.round(2),
          payable: @deal.commissions_payable?,
          payableAt: CommissionSettings.payable_at(@company),
          reasons: result[:reasons],
          participants: result[:participants].map do |p|
            { role: p[:role], userId: p[:user_id], userName: p[:user_name], estimatedAmount: p[:estimated_amount],
              components: p[:components].map { |c| { name: c[:name], amount: c[:amount], note: c[:note] }.compact } }
          end,
          unpaidPositions: result[:unpaid_positions].map { |p| { role: p[:role], userId: p[:user_id], userName: p[:user_name] } }
        }
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
          paidDate: payment.paid_date&.iso8601,
          amountPaid: payment.amount_paid,
          remainingBalance: payment.remaining_balance,
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

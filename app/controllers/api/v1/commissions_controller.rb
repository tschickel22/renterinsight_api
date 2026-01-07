# frozen_string_literal: true

module Api
  module V1
    class CommissionsController < ApplicationController
      before_action :set_company_scope
      before_action :set_commission_payment, only: [:show, :approve, :mark_paid, :reverse]

      # GET /api/v1/deals/:deal_id/commissions
      # List all commission payments for a deal
      def index
        return unless authorize_action!('commissions', 'read')

        deal = @company.deals.find(params[:deal_id])
        
        # Get all commission payments for this deal
        payments = @company.commission_payments
          .where(deal_id: deal.id)
          .includes(:payee_user, :commission_plan, :commission_payment_line_items)
          .order(created_at: :desc)

        # Apply location filtering if needed
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          payments = location_ids.any? ? 
            payments.where(location_id: location_ids) : 
            payments.none
        end

        render json: payments.map { |payment| serialize_payment(payment) }
      end

      # GET /api/v1/commissions/:id
      # Show a single commission payment with full details
      def show
        return unless authorize_action!('commissions', 'read')

        render json: serialize_payment_detail(@commission_payment)
      end

      # POST /api/v1/commissions/:id/approve
      # Approve a pending commission payment (RBAC: finance manager)
      def approve
        return unless authorize_action!('commissions', 'approve')

        if @commission_payment.status != 'pending'
          return render json: { error: 'Can only approve pending payments' }, status: :unprocessable_entity
        end

        @commission_payment.update!(
          status: 'approved',
          approved_by_user_id: current_user.id,
          approved_at: Time.current,
          notes: [
            @commission_payment.notes,
            "Approved by #{current_user.name} on #{Time.current.strftime('%Y-%m-%d %H:%M')}"
          ].compact.join("\n")
        )

        render json: serialize_payment_detail(@commission_payment)
      end

      # POST /api/v1/commissions/:id/mark_paid
      # Mark an approved commission as paid (RBAC: finance manager)
      def mark_paid
        return unless authorize_action!('commissions', 'mark_paid')

        if @commission_payment.status != 'approved'
          return render json: { error: 'Can only mark approved payments as paid' }, status: :unprocessable_entity
        end

        payment_params = params.permit(:payment_method, :payment_reference, :notes)

        @commission_payment.update!(
          status: 'paid',
          paid_by_user_id: current_user.id,
          paid_at: Time.current,
          payment_method: payment_params[:payment_method],
          payment_reference: payment_params[:payment_reference],
          notes: [
            @commission_payment.notes,
            payment_params[:notes],
            "Marked paid by #{current_user.name} on #{Time.current.strftime('%Y-%m-%d %H:%M')}"
          ].compact.join("\n")
        )

        render json: serialize_payment_detail(@commission_payment)
      end

      # POST /api/v1/commissions/:id/reverse
      # Reverse a commission payment (RBAC: finance manager)
      def reverse
        return unless authorize_action!('commissions', 'reverse')

        if @commission_payment.is_reversed
          return render json: { error: 'Payment is already reversed' }, status: :unprocessable_entity
        end

        reversal_params = params.permit(:reversal_reason)

        @commission_payment.update!(
          is_reversed: true,
          reversed_by_user_id: current_user.id,
          reversed_at: Time.current,
          reversal_reason: reversal_params[:reversal_reason],
          notes: [
            @commission_payment.notes,
            "REVERSED by #{current_user.name} on #{Time.current.strftime('%Y-%m-%d %H:%M')}",
            "Reason: #{reversal_params[:reversal_reason]}"
          ].compact.join("\n")
        )

        render json: serialize_payment_detail(@commission_payment)
      end

      # POST /api/v1/deals/:deal_id/commissions/preview
      # Preview commission calculation without creating payment
      def preview
        return unless authorize_action!('commissions', 'read')

        deal = @company.deals.find(params[:deal_id])
        preview_data = CommissionPaymentGeneratorService.preview_for_deal(deal)

        render json: preview_data
      end

      private

      def set_commission_payment
        @commission_payment = @company.commission_payments
          .includes(:payee_user, :deal, :commission_plan, :commission_payment_line_items)
          .find(params[:id])

        # RBAC location filtering
        if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          unless location_ids.empty? || location_ids.include?(@commission_payment.location_id)
            render json: { error: 'Not authorized' }, status: :forbidden
            return
          end
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Commission payment not found' }, status: :not_found
      end

      def serialize_payment(payment)
        {
          id: payment.id,
          paymentNumber: payment.payment_number,
          status: payment.status,
          amount: payment.amount,
          earnedDate: payment.earned_date,
          createdAt: payment.created_at,
          approvedAt: payment.approved_at,
          paidAt: payment.paid_at,
          isReversed: payment.is_reversed,
          deal: {
            id: payment.deal_id,
            name: payment.deal.name,
            dealNumber: payment.deal.id
          },
          payee: {
            id: payment.payee_user_id,
            name: payment.payee_user.name,
            email: payment.payee_user.email
          },
          plan: payment.commission_plan ? {
            id: payment.commission_plan.id,
            name: payment.commission_plan.name
          } : nil
        }
      end

      def serialize_payment_detail(payment)
        {
          id: payment.id,
          paymentNumber: payment.payment_number,
          status: payment.status,
          amount: payment.amount,
          earnedDate: payment.earned_date,
          approvedAt: payment.approved_at,
          approvedBy: payment.approved_by_user_id ? {
            id: payment.approved_by_user_id,
            name: payment.approved_by_user&.name
          } : nil,
          paidAt: payment.paid_at,
          paidBy: payment.paid_by_user_id ? {
            id: payment.paid_by_user_id,
            name: payment.paid_by_user&.name
          } : nil,
          paymentMethod: payment.payment_method,
          paymentReference: payment.payment_reference,
          isReversed: payment.is_reversed,
          reversedAt: payment.reversed_at,
          reversedBy: payment.reversed_by_user_id ? {
            id: payment.reversed_by_user_id,
            name: payment.reversed_by_user&.name
          } : nil,
          reversalReason: payment.reversal_reason,
          notes: payment.notes,
          locationId: payment.location_id,
          createdAt: payment.created_at,
          updatedAt: payment.updated_at,
          deal: {
            id: payment.deal_id,
            name: payment.deal.name,
            dealNumber: payment.deal.id,
            sellingPrice: payment.deal.selling_price,
            frontGross: payment.deal.front_gross,
            backGross: payment.deal.back_gross,
            totalGross: payment.deal.total_gross
          },
          payee: {
            id: payment.payee_user_id,
            name: payment.payee_user.name,
            email: payment.payee_user.email,
            role: payment.payee_user.role
          },
          plan: payment.commission_plan ? {
            id: payment.commission_plan.id,
            name: payment.commission_plan.name,
            description: payment.commission_plan.description
          } : nil,
          lineItems: payment.commission_payment_line_items.order(:display_order).map do |item|
            {
              id: item.id,
              description: item.description,
              calculationBasis: item.calculation_basis,
              calculationMethod: item.calculation_method,
              rate: item.rate,
              basisAmount: item.basis_amount,
              calculatedAmount: item.calculated_amount,
              displayOrder: item.display_order,
              calculationDetails: item.calculation_details
            }
          end
        }
      end
    end
  end
end

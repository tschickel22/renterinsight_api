# frozen_string_literal: true

module Api
  module V1
    class ManufacturerArTransactionsController < ApplicationController
      before_action :set_company_scope
      before_action :set_ar_transaction, only: [:show, :update, :mark_short_paid, :write_off]
      
      # GET /api/v1/manufacturer-ar-transactions
      def index
        return unless authorize_action!('service', 'read')
        
        @ar_transactions = if current_user.uses_rbac?
          if current_user.effective_admin?
            @company.manufacturer_ar_transactions.active
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              @company.manufacturer_ar_transactions.active.where(location_id: location_ids)
            else
              @company.manufacturer_ar_transactions.active
            end
          end
        else
          @company.manufacturer_ar_transactions.active
        end
        
        # Apply location selector filter
        if Current.location_filtered?
          @ar_transactions = @ar_transactions.where(location_id: Current.location_id)
        end
        
        @ar_transactions = @ar_transactions.includes(:manufacturer, :warranty_claim).recent
        
        # Apply filters
        @ar_transactions = @ar_transactions.by_status(params[:status]) if params[:status].present?
        @ar_transactions = @ar_transactions.by_manufacturer(params[:manufacturer_id]) if params[:manufacturer_id].present?
        @ar_transactions = @ar_transactions.overdue if params[:overdue] == 'true'
        
        render json: {
          data: @ar_transactions.map { |t| t.as_json }
        }
      end
      
      # GET /api/v1/manufacturer-ar-transactions/:id
      def show
        return unless authorize_action!('service', 'read')
        
        render json: {
          data: @ar_transaction.as_json(include_payments: true)
        }
      end
      
      # PATCH /api/v1/manufacturer-ar-transactions/:id
      def update
        return unless authorize_action!('service', 'update')
        
        if @ar_transaction.update(ar_transaction_params)
          render json: { data: @ar_transaction.as_json }
        else
          render json: { errors: @ar_transaction.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/manufacturer-ar-transactions/:id/mark-short-paid
      def mark_short_paid
        return unless authorize_action!('service', 'update')
        
        final_amount = params[:final_amount].to_f
        reason = params[:reason]
        
        if final_amount <= 0
          return render json: { errors: ['Final amount must be greater than 0'] }, status: :unprocessable_entity
        end
        
        if reason.blank?
          return render json: { errors: ['Reason is required'] }, status: :unprocessable_entity
        end
        
        begin
          @ar_transaction.mark_short_paid!(
            final_amount: final_amount,
            reason: reason,
            recorded_by: current_user.name || current_user.email
          )
          
          render json: {
            data: @ar_transaction.as_json,
            message: 'Transaction marked as short paid'
          }
        rescue ArgumentError => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/manufacturer-ar-transactions/:id/write-off
      def write_off
        return unless authorize_action!('service', 'update')
        
        reason = params[:reason]
        
        if reason.blank?
          return render json: { errors: ['Write-off reason is required'] }, status: :unprocessable_entity
        end
        
        begin
          @ar_transaction.write_off!(
            reason: reason,
            written_off_by: current_user.name || current_user.email
          )
          
          render json: {
            data: @ar_transaction.as_json,
            message: 'Transaction written off'
          }
        rescue ArgumentError => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end
      end
      
      # GET /api/v1/manufacturer-ar-transactions/stats
      def stats
        return unless authorize_action!('service', 'read')
        
        transactions = @company.manufacturer_ar_transactions.active
        
        # Apply location selector filter for stats
        if Current.location_filtered?
          transactions = transactions.where(location_id: Current.location_id)
        end
        
        stats_data = {
          total: transactions.count,
          open: transactions.open.count,
          partial: transactions.partial.count,
          paid: transactions.paid.count,
          overdue: transactions.overdue.count,
          total_outstanding: transactions.outstanding.sum(:amount_outstanding),
          total_original: transactions.sum(:original_claim_amount),
          total_paid: transactions.sum(:amount_paid_to_date)
        }
        
        render json: { data: stats_data }
      end
      
      private
      
      def set_ar_transaction
        @ar_transaction = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            @company.manufacturer_ar_transactions.active.where(location_id: location_ids).find(params[:id])
          else
            @company.manufacturer_ar_transactions.active.find(params[:id])
          end
        else
          @company.manufacturer_ar_transactions.active.find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'AR transaction not found or access denied' }, status: :not_found
        return
      end
      
      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [ManufacturerArTransactionsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [ManufacturerArTransactionsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [ManufacturerArTransactionsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [ManufacturerArTransactionsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end
      
      def ar_transaction_params
        params.require(:manufacturer_ar_transaction).permit(
          :expected_payment_date,
          :notes
        )
      end
    end
  end
end

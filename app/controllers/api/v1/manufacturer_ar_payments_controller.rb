# frozen_string_literal: true

module Api
  module V1
    class ManufacturerArPaymentsController < ApplicationController
      before_action :set_company_scope
      before_action :set_ar_payment, only: [:show, :upload_attachments, :destroy]
      
      # GET /api/v1/manufacturer-ar-payments
      def index
        return unless authorize_action!('service', 'read')
        
        # Get payments through AR transactions to respect tenant isolation
        ar_transaction_ids = if current_user.uses_rbac?
          if current_user.effective_admin?
            @company.manufacturer_ar_transactions.pluck(:id)
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              @company.manufacturer_ar_transactions.where(location_id: location_ids).pluck(:id)
            else
              @company.manufacturer_ar_transactions.pluck(:id)
            end
          end
        else
          @company.manufacturer_ar_transactions.pluck(:id)
        end
        
        @ar_payments = ManufacturerArPayment.where(
          company_id: @company.id,
          manufacturer_ar_transaction_id: ar_transaction_ids
        ).recent
        
        # Apply filters
        @ar_payments = @ar_payments.by_method(params[:payment_method]) if params[:payment_method].present?
        if params[:start_date].present? && params[:end_date].present?
          @ar_payments = @ar_payments.by_date_range(params[:start_date], params[:end_date])
        end
        @ar_payments = @ar_payments.for_manufacturer(params[:manufacturer_id]) if params[:manufacturer_id].present?
        
        render json: {
          data: @ar_payments.map { |p| p.as_json }
        }
      end
      
      # GET /api/v1/manufacturer-ar-payments/:id
      def show
        return unless authorize_action!('service', 'read')
        
        render json: {
          data: @ar_payment.as_json.merge(
            attachments: @ar_payment.attachments.map { |a| serialize_attachment(a) }
          )
        }
      end
      
      # POST /api/v1/manufacturer-ar-payments
      # Record a new payment (done via warranty_claims_controller#record_payment)
      # This endpoint is for direct creation if needed
      def create
        return unless authorize_action!('service', 'create')
        
        ar_transaction = @company.manufacturer_ar_transactions.find(params[:manufacturer_ar_transaction_id])
        
        begin
          @ar_payment = ar_transaction.record_payment!(
            amount: params[:amount].to_f,
            payment_date: params[:payment_date] || Date.current,
            payment_method: params[:payment_method],
            reference_number: params[:reference_number],
            notes: params[:notes],
            recorded_by: current_user.name || current_user.email
          )
          
          render json: {
            data: @ar_payment.as_json,
            message: 'Payment recorded successfully'
          }, status: :created
        rescue ArgumentError => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/manufacturer-ar-payments/:id/upload-attachments
      # Upload check images, remittance advice, etc.
      def upload_attachments
        return unless authorize_action!('service', 'update')
        
        if params[:files].present?
          params[:files].each do |file|
            @ar_payment.attachments.attach(file)
          end
          
          render json: {
            data: @ar_payment.as_json.merge(
              attachments: @ar_payment.attachments.map { |a| serialize_attachment(a) }
            ),
            message: 'Files uploaded successfully'
          }
        else
          render json: { errors: ['No files provided'] }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/manufacturer-ar-payments/:id
      # Delete a payment (only if it hasn't been reconciled)
      def destroy
        return unless authorize_action!('service', 'delete')
        
        # Get the AR transaction before destroying payment
        ar_transaction = @ar_payment.manufacturer_ar_transaction
        
        # Store amount for recalculation
        payment_amount = @ar_payment.amount
        
        @ar_payment.destroy
        
        # Recalculate AR transaction amounts
        ar_transaction.reload
        ar_transaction.amount_paid_to_date = ar_transaction.manufacturer_ar_payments.sum(:amount)
        ar_transaction.amount_outstanding = ar_transaction.original_claim_amount - ar_transaction.amount_paid_to_date
        
        if ar_transaction.amount_outstanding > 0
          ar_transaction.status = ar_transaction.amount_paid_to_date > 0 ? 'partial' : 'open'
          ar_transaction.paid_in_full_date = nil
        end
        
        ar_transaction.save!
        
        head :no_content
      end
      
      private
      
      def set_ar_payment
        # Get through company to ensure tenant isolation
        ar_transaction_ids = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            @company.manufacturer_ar_transactions.where(location_id: location_ids).pluck(:id)
          else
            @company.manufacturer_ar_transactions.pluck(:id)
          end
        else
          @company.manufacturer_ar_transactions.pluck(:id)
        end
        
        @ar_payment = ManufacturerArPayment.find_by!(
          id: params[:id],
          company_id: @company.id,
          manufacturer_ar_transaction_id: ar_transaction_ids
        )
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Payment not found or access denied' }, status: :not_found
        return
      end
      
      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [ManufacturerArPaymentsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [ManufacturerArPaymentsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [ManufacturerArPaymentsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [ManufacturerArPaymentsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end
      
      def serialize_attachment(attachment)
        {
          id: attachment.id,
          filename: attachment.filename.to_s,
          contentType: attachment.content_type,
          byteSize: attachment.byte_size,
          url: rails_blob_url(attachment, only_path: false)
        }
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module V1
    class WarrantyClaimsController < ApplicationController
      before_action :set_company_scope
      before_action :set_warranty_claim, only: [:show, :update, :submit, :resubmit, :reopen, :record_payment, :close]
      
      # GET /api/v1/warranty-claims
      def index
        return unless authorize_action!('service', 'read')
        
        # STRICT TENANT ISOLATION: Only return warranty claims from current user's company
        @warranty_claims = if current_user.uses_rbac?
          if current_user.effective_admin?
            @company.warranty_claims.active
          else
            location_ids = permission_service.accessible_location_ids
            if location_ids.any?
              @company.warranty_claims.active.where(location_id: location_ids)
            else
              @company.warranty_claims.active
            end
          end
        else
          @company.warranty_claims.active
        end
        
        # Apply location selector filter
        if Current.location_filtered?
          @warranty_claims = @warranty_claims.where(location_id: Current.location_id)
        end
        
        @warranty_claims = @warranty_claims.includes(:manufacturer, :service_ticket).recent
        
        # Apply filters
        @warranty_claims = @warranty_claims.by_status(params[:status]) if params[:status].present?
        @warranty_claims = @warranty_claims.by_manufacturer(params[:manufacturer_id]) if params[:manufacturer_id].present?
        
        # Pagination
        page = (params[:page] || 1).to_i
        per_page = (params[:per_page] || 50).to_i
        per_page = [per_page, 200].min  # Cap at 200
        total = @warranty_claims.count
        @warranty_claims = @warranty_claims.offset((page - 1) * per_page).limit(per_page)
        
        render json: {
          data: @warranty_claims.map { |claim| claim.as_json },
          meta: {
            total: total,
            page: page,
            per_page: per_page,
            total_pages: (total.to_f / per_page).ceil
          }
        }
      end
      
      # GET /api/v1/warranty-claims/:id
      def show
        return unless authorize_action!('service', 'read')
        
        render json: {
          data: @warranty_claim.as_json.merge(
            attachments: @warranty_claim.attachments.map { |a| serialize_attachment(a) }
          )
        }
      end
      
      # POST /api/v1/warranty-claims
      # Create a warranty claim from a service ticket
      def create
        return unless authorize_action!('service', 'create')
        
        service_ticket = @company.service_tickets.find(params[:warranty_claim][:service_ticket_id])
        
        @warranty_claim = WarrantyClaim.new(warranty_claim_params)
        @warranty_claim.company = @company
        @warranty_claim.location_id = service_ticket.location_id
        @warranty_claim.service_ticket = service_ticket
        
        # Auto-assign location from selector if not set
        @warranty_claim.location_id ||= Current.location_id if Current.location_id.present?
        
        if @warranty_claim.save
          # Update service ticket
          service_ticket.update!(
            warranty_claim_id: @warranty_claim.id,
            is_warranty_confirmed: true,
            status: 'waiting_on_manufacturer'
          )
          
          render json: { data: @warranty_claim.as_json }, status: :created
        else
          render json: { errors: @warranty_claim.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH /api/v1/warranty-claims/:id
      def update
        return unless authorize_action!('service', 'update')
        
        if @warranty_claim.update(warranty_claim_params)
          render json: { data: @warranty_claim.as_json }
        else
          render json: { errors: @warranty_claim.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/warranty-claims/:id/submit
      def submit
        return unless authorize_action!('service', 'update')
        
        if @warranty_claim.submit!(current_user.name || current_user.email)
          render json: { 
            data: @warranty_claim.as_json,
            message: 'Warranty claim submitted successfully'
          }
        else
          render json: { 
            errors: ['Unable to submit warranty claim. Please ensure all required fields are filled.'] 
          }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/warranty-claims/:id/resubmit
      def resubmit
        return unless authorize_action!('service', 'update')
        
        unless @warranty_claim.can_be_resubmitted?
          return render json: { 
            errors: ['Warranty claim cannot be resubmitted'] 
          }, status: :unprocessable_entity
        end
        
        if @warranty_claim.resubmit!(current_user.name || current_user.email)
          render json: { 
            data: @warranty_claim.as_json,
            message: 'Warranty claim resubmitted successfully'
          }
        else
          render json: { 
            errors: ['Unable to resubmit warranty claim'] 
          }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/warranty-claims/:id/reopen
      def reopen
        return unless authorize_action!('service', 'update')
        
        unless @warranty_claim.closed?
          return render json: { 
            errors: ['Only closed warranty claims can be reopened'] 
          }, status: :unprocessable_entity
        end
        
        # Set status to 'submitted' so manufacturer can review again
        if @warranty_claim.update(status: 'submitted', closed_at: nil, reopened_at: Time.current)
          render json: { 
            data: @warranty_claim.as_json,
            message: 'Warranty claim reopened successfully'
          }
        else
          render json: { 
            errors: ['Unable to reopen warranty claim'] 
          }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/warranty-claims/:id/record-payment
      def record_payment
        return unless authorize_action!('service', 'update')
        
        unless @warranty_claim.approved?
          return render json: { 
            errors: ['Can only record payments for approved claims'] 
          }, status: :unprocessable_entity
        end
        
        ar_transaction = @warranty_claim.manufacturer_ar_transaction
        
        unless ar_transaction
          return render json: { 
            errors: ['AR transaction not found'] 
          }, status: :not_found
        end
        
        begin
          payment = ar_transaction.record_payment!(
            amount: params[:amount].to_f,
            payment_date: params[:payment_date] || Date.current,
            payment_method: params[:payment_method],
            reference_number: params[:reference_number],
            notes: params[:notes],
            recorded_by: current_user.name || current_user.email
          )
          
          render json: { 
            data: payment.as_json,
            message: 'Payment recorded successfully'
          }, status: :created
        rescue ArgumentError => e
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end
      end
      
      # POST /api/v1/warranty-claims/:id/close
      def close
        return unless authorize_action!('service', 'update')
        
        if @warranty_claim.close!(current_user.name || current_user.email)
          render json: { 
            data: @warranty_claim.as_json,
            message: 'Warranty claim closed successfully'
          }
        else
          render json: { 
            errors: ['Unable to close warranty claim'] 
          }, status: :unprocessable_entity
        end
      end
      
      # GET /api/v1/warranty-claims/stats
      def stats
        return unless authorize_action!('service', 'read')
        
        claims = @company.warranty_claims.active
        
        # Apply location selector filter for stats
        if Current.location_filtered?
          claims = claims.where(location_id: Current.location_id)
        end
        
        stats_data = {
          total: claims.count,
          draft: claims.draft.count,
          submitted: claims.submitted.count,
          under_review: claims.under_review.count,
          approved: claims.approved.count,
          denied: claims.denied.count,
          closed: claims.closed.count,
          total_estimated: claims.sum(:estimated_amount),
          total_approved: claims.approved.sum(:approved_amount),
          total_ar_outstanding: @company.manufacturer_ar_transactions.outstanding.sum(:amount_outstanding)
        }
        
        render json: { data: stats_data }
      end
      
      private
      
      def set_warranty_claim
        @warranty_claim = if current_user.uses_rbac? && !current_user.effective_admin?
          location_ids = permission_service.accessible_location_ids
          if location_ids.any?
            @company.warranty_claims.active.where(location_id: location_ids).find(params[:id])
          else
            @company.warranty_claims.active.find(params[:id])
          end
        else
          @company.warranty_claims.active.find(params[:id])
        end
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Warranty claim not found or access denied' }, status: :not_found
        return
      end
      
      def set_company_scope
        unless current_user
          Rails.logger.error "🚫 [WarrantyClaimsController] No authenticated user found"
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          Rails.logger.error "🚫 [WarrantyClaimsController] No company context available"
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          Rails.logger.error "🚫 [WarrantyClaimsController] Company #{company_id} not found"
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
        
        Rails.logger.info "✅ [WarrantyClaimsController] Company scope set: #{@company.name} (ID: #{@company.id})"
      end
      
      def warranty_claim_params
        params.require(:warranty_claim).permit(
          :manufacturer_id,
          :estimated_amount,
          :approved_amount,
          :client_copay_amount,
          :manufacturer_claim_number,
          :notes_internal,
          :notes_to_manufacturer,
          :manufacturer_response,
          :denial_reason,
          parts: [:description, :part_number, :quantity, :cost],
          labor: [:description, :hours, :rate]
        )
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

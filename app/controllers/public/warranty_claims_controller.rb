# frozen_string_literal: true

module Public
  class WarrantyClaimsController < ApplicationController
    skip_before_action :authenticate_user! # No login required
    skip_before_action :set_company_scope # No company scoping needed
    
    before_action :set_warranty_claim_by_token
    
    # GET /public/warranty-claims/:token
    # Manufacturer views warranty claim via email link
    def show
      @warranty_claim.increment_views!
      
      render json: {
        data: {
          id: @warranty_claim.id,
          claimNumber: @warranty_claim.claim_number,
          status: @warranty_claim.status,
          estimatedAmount: @warranty_claim.estimated_amount,
          approvedAmount: @warranty_claim.approved_amount,
          parts: @warranty_claim.parts,
          labor: @warranty_claim.labor,
          notesToManufacturer: @warranty_claim.notes_to_manufacturer,
          manufacturerResponse: @warranty_claim.manufacturer_response,
          denialReason: @warranty_claim.denial_reason,
          submittedAt: @warranty_claim.submitted_at,
          manufacturerRespondedAt: @warranty_claim.manufacturer_responded_at,
          
          # Service ticket info
          serviceTicket: {
            title: @warranty_claim.service_ticket.title,
            description: @warranty_claim.service_ticket.description,
            scheduledDate: @warranty_claim.service_ticket.scheduled_date
          },
          
          # Vehicle info
          vehicle: @warranty_claim.service_ticket.vehicle ? {
            year: @warranty_claim.service_ticket.vehicle.year,
            make: @warranty_claim.service_ticket.vehicle.make,
            model: @warranty_claim.service_ticket.vehicle.model,
            vin: @warranty_claim.service_ticket.vehicle.vin,
            serialNumber: @warranty_claim.service_ticket.vehicle.serial_number
          } : nil,
          
          # Customer info (limited)
          customer: @warranty_claim.service_ticket.contact ? {
            name: "#{@warranty_claim.service_ticket.contact.first_name} #{@warranty_claim.service_ticket.contact.last_name}".strip
          } : nil,
          
          # Company info
          company: {
            name: @warranty_claim.company.name,
            phone: Setting.get_with_fallback('company_phone', @warranty_claim.company_id),
            email: Setting.get_with_fallback('company_email', @warranty_claim.company_id)
          },
          
          # Attachments
          attachments: @warranty_claim.attachments.map { |a| serialize_attachment(a) },
          
          # Calculated totals
          partsTotal: @warranty_claim.parts_total,
          laborTotal: @warranty_claim.labor_total,
          totalAmount: @warranty_claim.total_amount
        }
      }
    end
    
    # POST /public/warranty-claims/:token/respond
    # Manufacturer approves/denies/requests info
    def respond
      action = params[:action_type] # 'approve', 'deny', 'request_info'
      
      case action
      when 'approve'
        handle_approve
      when 'deny'
        handle_deny
      when 'request_info'
        handle_request_info
      else
        render json: { errors: ['Invalid action type'] }, status: :unprocessable_entity
      end
    end
    
    private
    
    def set_warranty_claim_by_token
      @warranty_claim = WarrantyClaim.find_by!(public_token: params[:token])
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'Warranty claim not found' }, status: :not_found
    end
    
    def handle_approve
      approved_amount = params[:approved_amount].to_f
      response_text = params[:response_text]
      
      if approved_amount <= 0
        return render json: { errors: ['Approved amount must be greater than 0'] }, status: :unprocessable_entity
      end
      
      if @warranty_claim.approve!(approved_amount, response_text)
        # TODO: Send notification email to company (Phase 4)
        Rails.logger.info("📧 Manufacturer approved claim #{@warranty_claim.claim_number} for $#{approved_amount}")
        
        render json: { 
          message: 'Warranty claim approved successfully',
          data: {
            status: @warranty_claim.status,
            approvedAmount: @warranty_claim.approved_amount
          }
        }
      else
        render json: { errors: ['Unable to approve warranty claim'] }, status: :unprocessable_entity
      end
    end
    
    def handle_deny
      denial_reason = params[:denial_reason]
      
      if denial_reason.blank?
        return render json: { errors: ['Denial reason is required'] }, status: :unprocessable_entity
      end
      
      if @warranty_claim.deny!(denial_reason)
        # TODO: Send notification email to company (Phase 4)
        Rails.logger.info("📧 Manufacturer denied claim #{@warranty_claim.claim_number}")
        
        render json: { 
          message: 'Warranty claim denied',
          data: {
            status: @warranty_claim.status,
            denialReason: @warranty_claim.denial_reason
          }
        }
      else
        render json: { errors: ['Unable to deny warranty claim'] }, status: :unprocessable_entity
      end
    end
    
    def handle_request_info
      request_message = params[:request_message]
      
      if request_message.blank?
        return render json: { errors: ['Request message is required'] }, status: :unprocessable_entity
      end
      
      if @warranty_claim.mark_under_review!
        # Update with request message
        @warranty_claim.update!(
          manufacturer_response: request_message
        )
        
        # TODO: Send notification email to company (Phase 4)
        Rails.logger.info("📧 Manufacturer requested more info for claim #{@warranty_claim.claim_number}")
        
        render json: { 
          message: 'Request sent successfully',
          data: {
            status: @warranty_claim.status,
            manufacturerResponse: @warranty_claim.manufacturer_response
          }
        }
      else
        render json: { errors: ['Unable to process request'] }, status: :unprocessable_entity
      end
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

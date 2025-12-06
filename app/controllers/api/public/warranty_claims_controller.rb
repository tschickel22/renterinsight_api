# frozen_string_literal: true

# Api::Public::WarrantyClaimsController
# 
# Handles manufacturer access to warranty claims via public token links
# NO AUTHENTICATION REQUIRED - Uses secure public tokens instead
#
# Routes:
#   GET  /w/:token      - View claim details
#   POST /w/:token/respond - Submit manufacturer response

module Api
  module Public
    class WarrantyClaimsController < ApplicationController
      skip_before_action :authenticate, raise: false
      skip_before_action :set_company_scope, raise: false
      skip_before_action :verify_authenticity_token, raise: false, only: [:respond]
      
      # GET /w/:token
      # Public view of warranty claim for manufacturers
      def show
        claim = WarrantyClaim.find_by_public_token!(params[:token])
        
        # Increment view counter
        claim.increment_views!
        
        render json: {
          success: true,
          data: claim.as_json(
            include: {
              service_ticket: {
                only: [:id, :title, :description, :scheduled_date],
                methods: [:vehicle_info]
              },
              manufacturer: {
                only: [:id, :name]
              },
              company: {
                only: [:id, :name]
              }
            }
          ).merge(
            # Add computed fields
            'partsTotal' => claim.parts_total,
            'laborTotal' => claim.labor_total,
            'totalAmount' => claim.total_amount,
            'customer' => customer_info(claim),
            'vehicle' => vehicle_info(claim),
            'company' => company_info(claim),
            'attachments' => attachment_info(claim)
          )
        }
      rescue ActiveRecord::RecordNotFound
        render json: {
          success: false,
          errors: ['Warranty claim not found or link has expired']
        }, status: :not_found
      rescue => e
        Rails.logger.error("Public warranty claim error: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        
        render json: {
          success: false,
          errors: ['An error occurred loading the warranty claim']
        }, status: :internal_server_error
      end
      
      # POST /w/:token/respond
      # Manufacturer submits response to warranty claim
      def respond
        claim = WarrantyClaim.find_by_public_token!(params[:token])
        
        # Verify claim is in a state that can receive responses
        unless claim.pending?
          render json: {
            success: false,
            errors: ['This claim has already been responded to']
          }, status: :unprocessable_entity
          return
        end
        
        action_type = params[:action_type]
        
        case action_type
        when 'approve'
          handle_approval(claim)
        when 'deny'
          handle_denial(claim)
        when 'request_info'
          handle_request_info(claim)
        else
          render json: {
            success: false,
            errors: ['Invalid action type']
          }, status: :unprocessable_entity
        end
      rescue ActiveRecord::RecordNotFound
        render json: {
          success: false,
          errors: ['Warranty claim not found or link has expired']
        }, status: :not_found
      rescue => e
        Rails.logger.error("Public warranty claim response error: #{e.message}")
        Rails.logger.error(e.backtrace.first(5).join("\n"))
        
        render json: {
          success: false,
          errors: [e.message]
        }, status: :internal_server_error
      end
      
      private
      
      def handle_approval(claim)
        approved_amount = params[:approved_amount].to_f
        response_text = params[:response_text]
        
        if approved_amount <= 0
          render json: {
            success: false,
            errors: ['Approved amount must be greater than 0']
          }, status: :unprocessable_entity
          return
        end
        
        if claim.approve!(approved_amount, response_text)
          render json: {
            success: true,
            message: 'Warranty claim approved successfully',
            data: claim.as_json
          }
        else
          render json: {
            success: false,
            errors: claim.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      def handle_denial(claim)
        denial_reason = params[:denial_reason]
        
        if denial_reason.blank?
          render json: {
            success: false,
            errors: ['Denial reason is required']
          }, status: :unprocessable_entity
          return
        end
        
        if claim.deny!(denial_reason)
          render json: {
            success: true,
            message: 'Warranty claim denied',
            data: claim.as_json
          }
        else
          render json: {
            success: false,
            errors: claim.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      def handle_request_info(claim)
        request_message = params[:request_message]
        
        if request_message.blank?
          render json: {
            success: false,
            errors: ['Request message is required']
          }, status: :unprocessable_entity
          return
        end
        
        # Mark as under review and add note
        if claim.mark_under_review!
          claim.update!(manufacturer_response: request_message)
          
          render json: {
            success: true,
            message: 'Information request sent successfully',
            data: claim.as_json
          }
        else
          render json: {
            success: false,
            errors: claim.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      def customer_info(claim)
        ticket = claim.service_ticket
        return nil unless ticket
        
        if ticket.contact
          {
            name: "#{ticket.contact.first_name} #{ticket.contact.last_name}".strip
          }
        elsif ticket.account
          {
            name: ticket.account.name
          }
        else
          nil
        end
      end
      
      def vehicle_info(claim)
        vehicle = claim.service_ticket&.vehicle
        return nil unless vehicle
        
        {
          year: vehicle.year,
          make: vehicle.make,
          model: vehicle.model,
          vin: vehicle.vin,
          serialNumber: vehicle.serial_number
        }
      end
      
      def company_info(claim)
        company = claim.company
        location = claim.location
        
        # Get phone and email from notification service helpers
        phone = WarrantyNotificationService.get_company_phone(company, location)
        email = WarrantyNotificationService.get_company_email(company)
        
        {
          id: company.id,
          name: company.name,
          phone: phone,
          email: email
        }
      end
      
      def attachment_info(claim)
        return [] unless claim.attachments.attached?
        
        claim.attachments.map do |attachment|
          {
            id: attachment.id,
            filename: attachment.filename.to_s,
            contentType: attachment.content_type,
            byteSize: attachment.byte_size,
            url: rails_blob_url(attachment)
          }
        end
      end
    end
  end
end

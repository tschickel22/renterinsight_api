# frozen_string_literal: true

module Api
  class InvitationsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_company_scope
    before_action :set_invitation, only: [:show, :resend, :destroy]
    
    # GET /api/companies/:company_id/invitations
    def index
      verify_company_access!
      
      invitations = @company.invitations
                            .where(invitation_type: params[:invitation_type] || 'company_user')
                            .recent
      
      render json: {
        success: true,
        invitations: invitations.map { |inv| invitation_json(inv) }
      }, status: :ok
    end
    
    # GET /api/invitations/:id
    def show
      render json: {
        success: true,
        invitation: invitation_json(@invitation)
      }, status: :ok
    end
    
    # POST /api/companies/:company_id/invitations
    def create
      verify_company_access!
      
      # Log incoming params for debugging
      received_location_ids = params[:location_ids] || params[:locationIds] || []
      received_location_role = params[:location_role] || params[:locationRole]
      
      Rails.logger.info "📨 [InvitationsController] Creating invitation"
      Rails.logger.info "📨 [InvitationsController] email: #{params[:email]}"
      Rails.logger.info "📨 [InvitationsController] role: #{params[:role]}"
      Rails.logger.info "📨 [InvitationsController] location_ids (snake): #{params[:location_ids].inspect}"
      Rails.logger.info "📨 [InvitationsController] locationIds (camel): #{params[:locationIds].inspect}"
      Rails.logger.info "📨 [InvitationsController] resolved location_ids: #{received_location_ids.inspect}"
      Rails.logger.info "📨 [InvitationsController] location_role (snake): #{params[:location_role]}"
      Rails.logger.info "📨 [InvitationsController] locationRole (camel): #{params[:locationRole]}"
      Rails.logger.info "📨 [InvitationsController] resolved location_role: #{received_location_role}"
      
      service = InvitationService.new(
        invited_by: current_user,
        company: @company
      )
      
      result = service.create_invitation(
        invitation_type: params[:invitation_type] || params[:invitationType] || 'company_user',
        email: params[:email],
        phone: params[:phone],
        recipient_name: params[:recipient_name] || params[:recipientName],
        recipient_data: params[:recipient_data] || {},
        role: params[:role],
        permissions: params[:permissions] || [],
        delivery_method: params[:delivery_method] || params[:deliveryMethod] || 'email',
        message: params[:message],
        location_ids: received_location_ids,
        location_role: received_location_role
      )
      
      if result[:success]
        response_data = {
          success: true,
          invitation: invitation_json(result[:invitation]),
          message: result[:message]
        }
        
        if Rails.env.development? && result[:invitation].token.present?
          response_data[:token] = result[:invitation].token
          response_data[:invitation_url] = "#{ENV['FRONTEND_URL'] || 'https://localhost:5173'}/invitations/accept?token=#{result[:invitation].token}"
        end
        
        render json: response_data, status: :created
      else
        render json: {
          success: false,
          error: result[:error]
        }, status: :unprocessable_entity
      end
    end
    
    # POST /api/invitations/:id/resend
    def resend
      service = InvitationService.new(
        invited_by: current_user,
        company: @invitation.company
      )
      
      result = service.resend_invitation(@invitation.id)
      
      if result[:success]
        render json: {
          success: true,
          invitation: invitation_json(result[:invitation]),
          message: 'Invitation resent successfully'
        }, status: :ok
      else
        render json: {
          success: false,
          error: result[:error]
        }, status: :unprocessable_entity
      end
    end
    
    # DELETE /api/invitations/:id (revoke)
    def destroy
      service = InvitationService.new(
        invited_by: current_user,
        company: @invitation.company
      )
      
      result = service.revoke_invitation(
        @invitation.id,
        reason: params[:reason]
      )
      
      if result[:success]
        render json: {
          success: true,
          message: 'Invitation cancelled successfully'
        }, status: :ok
      else
        render json: {
          success: false,
          error: result[:error]
        }, status: :unprocessable_entity
      end
    end
    
    private
    
    def set_invitation
      @invitation = @company.invitations.find_by(id: params[:id])
      unless @invitation
        render json: { success: false, error: 'Invitation not found' }, status: :not_found
      end
    end
    
    def verify_company_access!
      requested_company_id = params[:company_id]
      
      return true unless requested_company_id.present?
      
      if requested_company_id.to_s != @company.id.to_s
        unless current_user.platform_admin? || current_user.super_admin?
          Rails.logger.error "🚫 [InvitationsController] User #{current_user.id} attempted to access company #{requested_company_id} but belongs to #{@company.id}"
          render json: { success: false, error: 'Forbidden - Cannot access other company invitations' }, status: :forbidden
          return false
        end
        
        requested_company = ::Company.find_by(id: requested_company_id)
        if requested_company
          @company = requested_company
          Rails.logger.info "✅ [InvitationsController] Platform admin accessing company #{@company.id}"
        else
          render json: { success: false, error: 'Company not found' }, status: :not_found
          return false
        end
      end
      
      true
    end
    
    def invitation_json(invitation)
      {
        id: invitation.id,
        invitationType: invitation.invitation_type,
        email: invitation.email,
        phone: invitation.phone,
        status: invitation.status,
        role: invitation.role,
        recipientName: invitation.recipient_name,
        deliveryMethod: invitation.delivery_method,
        message: invitation.message,
        locationIds: invitation.location_ids || [],
        locationRole: invitation.location_role,
        sentAt: invitation.sent_at&.iso8601,
        expiresAt: invitation.expires_at&.iso8601,
        acceptedAt: invitation.accepted_at&.iso8601,
        lastSentAt: invitation.last_sent_at&.iso8601,
        resendCount: invitation.resend_count,
        attempts: invitation.attempts,
        viewedAt: invitation.viewed_at&.iso8601,
        createdAt: invitation.created_at&.iso8601,
        updatedAt: invitation.updated_at&.iso8601,
        invitedBy: {
          id: invitation.invited_by.id,
          name: invitation.invited_by.name || invitation.invited_by.email,
          email: invitation.invited_by.email
        },
        company: invitation.company ? {
          id: invitation.company.id,
          name: invitation.company.name
        } : nil,
        locations: invitation.location_ids.present? ? Location.where(id: invitation.parsed_location_ids).map { |loc|
          { id: loc.id, name: loc.name, code: loc.code }
        } : []
      }
    end
  end
end

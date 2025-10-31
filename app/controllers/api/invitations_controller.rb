# frozen_string_literal: true

module Api
  class InvitationsController < ApplicationController
    before_action :set_invitation, only: [:show, :resend, :destroy]
    before_action :set_company, only: [:index, :create]
    
    # GET /api/companies/:company_id/invitations
    def index
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
        message: params[:message]
      )
      
      if result[:success]
        render json: {
          success: true,
          invitation: invitation_json(result[:invitation]),
          message: result[:message]
        }, status: :created
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
      @invitation = Invitation.find(params[:id])
    rescue ActiveRecord::RecordNotFound
      render json: { success: false, error: 'Invitation not found' }, status: :not_found
    end
    
    def set_company
      @company = ::Company.find(params[:company_id])
    rescue ActiveRecord::RecordNotFound
      render json: { success: false, error: 'Company not found' }, status: :not_found
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
        } : nil
      }
    end
  end
end

module Api
  class UsersController < ApplicationController
    # GET /api/users
    def index
      # Include deleted users if requested
      users = params[:include_deleted] == 'true' ? User.with_deleted : User.all
      
      # Filter by role if provided
      users = users.where(role: params[:role]) if params[:role].present?
      
      # Filter by status if provided
      users = users.where(status: params[:status]) if params[:status].present?
      
      # Search by name or email if provided
      if params[:search].present?
        search_term = "%#{params[:search]}%"
        users = users.where('name LIKE ? OR email LIKE ? OR first_name LIKE ? OR last_name LIKE ?', 
                           search_term, search_term, search_term, search_term)
      end
      
      render json: {
        success: true,
        users: users.map { |u| user_json(u) }
      }
    end
    
    # GET /api/users/:id
    def show
      user = User.find(params[:id])
      render json: {
        success: true,
        user: user_json(user)
      }
    end
    
    # POST /api/users
    def create
      user = User.new(user_params)
      
      if user.save
        render json: {
          success: true,
          user: user_json(user)
        }, status: :created
      else
        render json: {
          success: false,
          errors: user.errors.full_messages
        }, status: :unprocessable_entity
      end
    end
    
    # PUT/PATCH /api/users/:id
    def update
      user = User.find(params[:id])
      
      if user.update(user_params)
        render json: {
          success: true,
          user: user_json(user)
        }
      else
        render json: {
          success: false,
          errors: user.errors.full_messages
        }, status: :unprocessable_entity
      end
    end
    
    # DELETE /api/users/:id (soft delete)
    def destroy
      user = User.unscoped.find(params[:id])
      reason = params[:reason] || 'User deleted'
      user.soft_delete!(reason: reason)
      render json: { 
        success: true,
        message: 'User soft deleted successfully'
      }
    rescue StandardError => e
      render json: { 
        success: false, 
        error: e.message 
      }, status: :unprocessable_entity
    end
    
    # POST /api/users/:id/restore
    def restore
      user = User.unscoped.find(params[:id])
      
      if user.deleted_at.nil?
        render json: {
          success: false,
          error: 'User is not deleted'
        }, status: :unprocessable_entity
        return
      end
      
      user.restore!
      render json: {
        success: true,
        message: 'User restored successfully',
        user: user_json(user)
      }
    rescue StandardError => e
      render json: { 
        success: false, 
        error: e.message 
      }, status: :unprocessable_entity
    end
    
    private
    
    def user_params
      params.require(:user).permit(
        :email, :name, :first_name, :last_name, :role, :status, :phone, :password
      )
    end
    
    def user_json(user)
      # Use the user's invitation_id if available, otherwise try to find invitation
      invitation = nil
      if user.invitation_id
        invitation = Invitation.find_by(id: user.invitation_id)
      else
        # Fallback: find any invitation for this email (pending or accepted)
        invitation = Invitation.find_by(email: user.email)
      end
      
      {
        id: user.id,
        email: user.email,
        name: user.name || "#{user.first_name} #{user.last_name}".strip,
        firstName: user.first_name,
        lastName: user.last_name,
        role: user.role,
        status: user.status,
        userType: 'company',  # For now, assume all are company users
        phone: user.phone,
        mfaEnabled: user.mfa_enabled || false,
        lastLoginAt: user.last_sign_in_at&.iso8601,
        createdAt: user.created_at&.iso8601,
        updatedAt: user.updated_at&.iso8601,
        deletedAt: user.deleted_at&.iso8601,
        deletedReason: user.deleted_reason,
        companyId: invitation&.company_id,
        invitationId: user.invitation_id,
        permissions: user.permissions || []
      }
    end
  end
end

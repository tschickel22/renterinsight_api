module Api
  class UsersController < ApplicationController
    before_action :set_company_scope
    
    # GET /api/users
    def index
      # STRICT TENANT ISOLATION: Only return users from current user's company
      users = @company.users
      
      # Filter by role if provided
      users = users.where(role: params[:role]) if params[:role].present?
      
      # Filter by status if provided
      users = users.where(status: params[:status]) if params[:status].present?
      
      # Search by name or email if provided
      if params[:search].present?
        search_term = "%#{params[:search]}%"
        users = users.where('name LIKE ? OR email LIKE ?', search_term, search_term)
      end
      
      render json: users.map { |u| user_json(u) }
    end
    
    # GET /api/users/:id
    def show
      # STRICT TENANT ISOLATION: Only allow access to users in same company
      user = @company.users.find(params[:id])
      render json: user_json(user)
    rescue ActiveRecord::RecordNotFound
      render json: { error: 'User not found or access denied' }, status: :not_found
    end
    
    # POST /api/users
    def create
      # STRICT TENANT ISOLATION: Create user within current company
      user = @company.users.new(user_params)
      
      if user.save
        # Assign RBAC role if company uses RBAC system
        if @company.use_rbac_system && user.role.present?
          user.assign_rbac_role(
            user.role,
            company_id: @company.id,
            assigned_by: current_user
          )
          Rails.logger.info "✅ [Api::UsersController] Assigned RBAC role '#{user.role}' to new user #{user.id}"
        end
        
        render json: user_json(user), status: :created
      else
        render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
      end
    end
    
    # PUT/PATCH /api/users/:id
    def update
      # STRICT TENANT ISOLATION: Only update users in same company
      user = @company.users.find(params[:id])
      
      # Check if role is being changed
      new_role = params[:user][:role] if params[:user].present?
      role_changed = new_role.present? && new_role != user.role
      
      if user.update(user_params)
        # Handle RBAC role change if company uses RBAC system
        if role_changed && @company.use_rbac_system
          user.replace_rbac_role(
            new_role,
            company_id: @company.id,
            assigned_by: current_user
          )
          Rails.logger.info "✅ [Api::UsersController] Updated RBAC role to '#{new_role}' for user #{user.id}"
        end
        
        render json: {
          success: true,
          user: user_json(user),
          message: 'User updated successfully'
        }
      else
        render json: { 
          success: false,
          errors: user.errors.full_messages,
          error: user.errors.full_messages.join(', ')
        }, status: :unprocessable_entity
      end
    end
    
    # DELETE /api/users/:id
    def destroy
      # STRICT TENANT ISOLATION: Only delete users in same company
      user = @company.users.find(params[:id])
      reason = params[:reason] || 'No reason provided'
      
      if user.destroy
        render json: {
          success: true,
          message: 'User deleted successfully',
          reason: reason
        }, status: :ok  # ← CRITICAL: Must explicitly set :ok, otherwise Rails returns 204 No Content
      else
        render json: { 
          success: false,
          errors: user.errors.full_messages,
          error: user.errors.full_messages.join(', ')
        }, status: :unprocessable_entity
      end
    end
    
    private
    
    def set_company_scope
      unless current_user
        Rails.logger.error "🚫 [UsersController] No authenticated user found"
        render json: { error: 'Authentication required' }, status: :unauthorized
        return
      end
      
      unless current_user.company_id.present?
        Rails.logger.error "🚫 [UsersController] User #{current_user.id} has no company_id"
        render json: { error: 'No company assigned' }, status: :forbidden
        return
      end
      
      @company = ::Company.find_by(id: current_user.company_id)
      
      if @company.nil?
        Rails.logger.error "🚫 [UsersController] Company #{current_user.company_id} not found"
        render json: { error: 'Company not found' }, status: :not_found
        return
      end
      
      Rails.logger.info "✅ [UsersController] Company scope set: #{@company.name} (ID: #{@company.id}) for user: #{current_user.email}"
    end
    
    def user_params
      params.require(:user).permit(
        :email, :name, :first_name, :last_name, :role, :status, :phone, :password
      )
    end
    
    def user_json(user)
      {
        id: user.id.to_s,
        email: user.email,
        name: user.name || "#{user.first_name} #{user.last_name}".strip,
        firstName: user.first_name,
        lastName: user.last_name,
        role: user.role,
        status: user.status,
        phone: user.phone,
        lastSignInAt: user.last_sign_in_at&.iso8601,
        createdAt: user.created_at&.iso8601,
        updatedAt: user.updated_at&.iso8601
      }
    end
  end
end

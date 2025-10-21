module Api
  class UsersController < ApplicationController
    # GET /api/users
    def index
      users = User.all
      
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
      user = User.find(params[:id])
      render json: user_json(user)
    end
    
    # POST /api/users
    def create
      user = User.new(user_params)
      
      if user.save
        render json: user_json(user), status: :created
      else
        render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
      end
    end
    
    # PUT/PATCH /api/users/:id
    def update
      user = User.find(params[:id])
      
      if user.update(user_params)
        render json: user_json(user)
      else
        render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
      end
    end
    
    # DELETE /api/users/:id
    def destroy
      user = User.find(params[:id])
      user.destroy
      head :no_content
    end
    
    private
    
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

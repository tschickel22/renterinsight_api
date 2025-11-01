# frozen_string_literal: true

module Api
  module Companies
    class UsersController < ApplicationController
      before_action :set_company
      before_action :set_user, only: [:show, :update, :destroy, :resend_invitation]
      
      # GET /api/companies/:company_id/users
      def index
        users = @company.users
        
        # Include deleted users if requested
        users = ::User.where(company_id: @company.id).with_deleted if params[:include_deleted] == 'true'
        
        render json: users.map { |user| serialize_user(user) }
      end
      
      # GET /api/companies/:company_id/users/:id
      def show
        render json: serialize_user(@user)
      end
      
      # POST /api/companies/:company_id/users
      def create
        @user = @company.users.new(user_params)
        
        # Generate temporary password
        temp_password = SecureRandom.alphanumeric(12)
        @user.password = temp_password
        @user.password_confirmation = temp_password
        
        if @user.save
          # Send invitation email
          # TODO: Implement invitation email sending
          
          render json: serialize_user(@user), status: :created
        else
          render json: { errors: @user.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # PATCH/PUT /api/companies/:company_id/users/:id
      def update
        if @user.update(user_params)
          render json: serialize_user(@user)
        else
          render json: { errors: @user.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/companies/:company_id/users/:id
      def destroy
        if @user.destroy
          head :no_content
        else
          render json: { errors: @user.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      # POST /api/companies/:company_id/users/:id/resend_invitation
      def resend_invitation
        # TODO: Implement resend invitation email
        
        render json: { message: 'Invitation sent successfully' }
      end
      
      private
      
      def set_company
        @company = ::Company.find(params[:company_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Company not found' }, status: :not_found
      end
      
      def set_user
        @user = @company.users.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'User not found' }, status: :not_found
      end
      
      def user_params
        params.require(:user).permit(
          :email,
          :first_name,
          :last_name,
          :phone,
          :role,
          :status,
          :title,
          :department
        )
      end
      
      def serialize_user(user)
        {
          id: user.id,
          email: user.email,
          firstName: user.first_name,
          lastName: user.last_name,
          phone: user.phone,
          role: user.role,
          status: user.status,
          title: user.title,
          department: user.department,
          createdAt: user.created_at,
          updatedAt: user.updated_at,
          deletedAt: user.respond_to?(:deleted_at) ? user.deleted_at : nil
        }
      end
    end
  end
end

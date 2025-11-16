# frozen_string_literal: true

module Api
  module V1
    class UsersController < ApplicationController
      before_action :set_user, only: [:show, :update, :destroy]
      before_action :authorize_company_access!
      before_action :authorize_user_management!, only: [:create, :update, :destroy]

      # GET /api/v1/users
      def index
        @users = current_company.users.where(deleted_at: nil)

        # Filter by status if provided
        if params[:status].present?
          @users = @users.where(status: params[:status])
        end

        # Filter by role if provided
        if params[:role].present?
          @users = @users.where(role: params[:role])
        end

        # Filter by location if provided
        if params[:location_id].present?
          location = current_company.locations.find(params[:location_id])
          @users = @users.joins(:user_locations)
                        .where(user_locations: { location_id: location.id, active: true })
                        .distinct
        end

        # Include deleted users if requested
        if params[:include_deleted] == 'true' && current_user.admin?
          @users = current_company.users
        end

        @users = @users.order(created_at: :desc)

        render json: {
          users: @users.map { |user| user_json(user) },
          meta: {
            total: @users.count,
            company_id: current_company.id
          }
        }
      end

      # GET /api/v1/users/:id
      def show
        render json: {
          user: user_json(@user, include_locations: true)
        }
      end

      # POST /api/v1/users
      def create
        @user = current_company.users.build(user_params)
        @user.status ||= 'active'

        # Generate temporary password if not provided
        unless params[:user][:password].present?
          @user.password = SecureRandom.hex(16)
          @user.password_confirmation = @user.password
        end

        if @user.save
          # Handle location assignments if provided
          if params[:location_ids].present?
            assign_locations_to_user(@user, params[:location_ids], params[:location_role])
          end

          render json: {
            user: user_json(@user, include_locations: true),
            message: 'User created successfully'
          }, status: :created
        else
          render json: {
            errors: @user.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/v1/users/:id
      def update
        # Track reason for audit
        reason = params[:reason] || 'Updated via API'

        if @user.update(user_params)
          # Handle location assignments if provided
          if params[:location_ids].present?
            sync_user_locations(@user, params[:location_ids], params[:location_role])
          end

          # Log the update
          Rails.logger.info("[UsersController] User #{@user.id} updated by #{current_user.id}: #{reason}")

          render json: {
            user: user_json(@user, include_locations: true),
            message: 'User updated successfully'
          }
        else
          render json: {
            errors: @user.errors.full_messages
          }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/users/:id
      def destroy
        # Soft delete
        if @user.update(deleted_at: Time.current, status: 'inactive')
          # Deactivate all location assignments
          @user.user_locations.update_all(active: false)

          render json: {
            message: 'User deleted successfully'
          }
        else
          render json: {
            errors: ['Failed to delete user']
          }, status: :unprocessable_entity
        end
      end

      # GET /api/v1/users/:id/locations
      def user_locations
        @user = current_company.users.find(params[:id])
        authorize_user_access!(@user)

        @locations = @user.locations.where(is_deleted: false)
                         .includes(:user_locations)

        render json: {
          locations: @locations.map do |location|
            ul = @user.user_locations.find_by(location_id: location.id)
            {
              id: location.id,
              name: location.name,
              code: location.code,
              city: location.city,
              state: location.state,
              location_role: ul&.location_role,
              active: ul&.active,
              assigned_at: ul&.created_at
            }
          end
        }
      end

      # POST /api/v1/users/:id/assign_location
      def assign_location
        @user = current_company.users.find(params[:id])
        authorize_user_management!

        location = current_company.locations.find(params[:location_id])
        location_role = params[:location_role] || 'location_staff'

        ul = location.assign_user(@user, role: location_role, assigned_by: current_user.id.to_s)

        render json: {
          user_location: {
            user_id: ul.user_id,
            location_id: ul.location_id,
            location_role: ul.location_role,
            active: ul.active
          },
          message: 'User assigned to location successfully'
        }
      rescue ActiveRecord::RecordInvalid => e
        render json: {
          errors: [e.message]
        }, status: :unprocessable_entity
      end

      # DELETE /api/v1/users/:id/remove_location/:location_id
      def remove_location
        @user = current_company.users.find(params[:id])
        authorize_user_management!

        location = current_company.locations.find(params[:location_id])
        location.remove_user(@user)

        render json: {
          message: 'User removed from location successfully'
        }
      end

      # POST /api/v1/users/bulk_activate
      def bulk_activate
        authorize_user_management!

        user_ids = params[:user_ids] || []
        users = current_company.users.where(id: user_ids)

        updated_count = 0
        users.each do |user|
          if user.update(status: 'active')
            updated_count += 1
          end
        end

        render json: {
          message: "#{updated_count} user(s) activated successfully",
          updated_count: updated_count
        }
      end

      # POST /api/v1/users/bulk_deactivate
      def bulk_deactivate
        authorize_user_management!

        user_ids = params[:user_ids] || []
        users = current_company.users.where(id: user_ids)

        updated_count = 0
        users.each do |user|
          if user.update(status: 'inactive')
            updated_count += 1
          end
        end

        render json: {
          message: "#{updated_count} user(s) deactivated successfully",
          updated_count: updated_count
        }
      end

      private

      def set_user
        @user = current_company.users.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'User not found' }, status: :not_found
      end

      def user_params
        params.require(:user).permit(
          :email,
          :first_name,
          :last_name,
          :display_name,
          :mobile,
          :role,
          :status,
          :password,
          :password_confirmation
        )
      end

      def user_json(user, include_locations: false)
        json = {
          id: user.id,
          email: user.email,
          first_name: user.first_name,
          last_name: user.last_name,
          display_name: user.name,
          mobile: user.try(:mobile),
          role: user.role,
          status: user.status,
          company_id: user.company_id,
          created_at: user.created_at,
          updated_at: user.updated_at,
          deleted_at: user.deleted_at
        }

        if include_locations
          json[:locations] = user.user_locations.includes(:location)
                                .where(active: true)
                                .map do |ul|
            {
              id: ul.location_id,
              name: ul.location.name,
              location_role: ul.location_role,
              assigned_at: ul.created_at
            }
          end
        end

        json
      end

      def current_company
        @current_company ||= ::Company.find_by(id: current_company_id)
      end

      def authorize_company_access!
        unless current_company.present?
          render json: { error: 'No company associated with user' }, status: :forbidden
        end
      end

      def authorize_user_management!
        # Only company admins can manage users
        # Location admins can only manage users within their locations (handled by location controller)
        unless current_user.admin?
          render json: { error: 'Admin access required' }, status: :forbidden
        end
      end

      def authorize_user_access!(user)
        # Company admins can access all users
        return if current_user.admin?

        # Users can access their own profile
        return if current_user.id == user.id

        # Otherwise, deny access
        render json: { error: 'Access denied' }, status: :forbidden
      end

      def assign_locations_to_user(user, location_ids, location_role = 'location_staff')
        location_ids = [location_ids] unless location_ids.is_a?(Array)
        
        location_ids.each do |location_id|
          location = current_company.locations.find_by(id: location_id)
          next unless location

          UserLocation.find_or_create_by!(
            user_id: user.id,
            location_id: location.id,
            company_id: current_company.id
          ) do |ul|
            ul.location_role = location_role || 'location_staff'
            ul.active = true
            ul.assigned_by = current_user.id.to_s
          end
        end
      end

      def sync_user_locations(user, location_ids, location_role = 'location_staff')
        location_ids = [location_ids] unless location_ids.is_a?(Array)
        
        # Deactivate locations not in the new list
        user.user_locations.where.not(location_id: location_ids).update_all(active: false)

        # Add or reactivate locations in the new list
        location_ids.each do |location_id|
          location = current_company.locations.find_by(id: location_id)
          next unless location

          ul = UserLocation.find_or_initialize_by(
            user_id: user.id,
            location_id: location.id,
            company_id: current_company.id
          )

          ul.location_role = location_role || ul.location_role || 'location_staff'
          ul.active = true
          ul.assigned_by = current_user.id.to_s if ul.new_record?
          ul.save!
        end
      end
    end
  end
end

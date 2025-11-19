# frozen_string_literal: true

module Api
  module V1
    class ActionsController < ApplicationController
      before_action :ensure_rbac_enabled
      before_action :set_action, only: [:show, :update, :destroy]
      before_action :authorize_action_management, except: [:index, :show]
      
      # GET /api/v1/actions
      # List all actions (system-level data)
      def index
        @actions = Action.order(:key)
        
        render json: {
          actions: @actions.map { |action| serialize_action(action) }
        }
      end
      
      # GET /api/v1/actions/:id
      # Show action details
      def show
        render json: {
          action: serialize_action(@action)
        }
      end
      
      # POST /api/v1/actions
      # Create new action (platform admin only)
      def create
        @action = Action.new(action_params)
        
        if @action.save
          render json: {
            action: serialize_action(@action),
            message: 'Action created successfully'
          }, status: :created
        else
          render json: {
            error: 'Failed to create action',
            errors: @action.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      # PATCH /api/v1/actions/:id
      # Update action (platform admin only)
      def update
        if @action.update(action_params)
          render json: {
            action: serialize_action(@action),
            message: 'Action updated successfully'
          }
        else
          render json: {
            error: 'Failed to update action',
            errors: @action.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/actions/:id
      # Delete action (platform admin only)
      def destroy
        @action.destroy
        
        render json: {
          message: 'Action deleted successfully'
        }
      end
      
      private
      
      def set_action
        @action = Action.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Action not found' }, status: :not_found
      end
      
      def ensure_rbac_enabled
        unless current_company.use_rbac_system
          render json: {
            error: 'RBAC system is not enabled for this company',
            message: 'Please contact your administrator to enable role-based access control'
          }, status: :forbidden
        end
      end
      
      def authorize_action_management
        unless current_user.super_admin?
          render json: {
            error: 'Forbidden - Only platform administrators can manage actions'
          }, status: :forbidden
        end
      end
      
      def action_params
        params.require(:action).permit(
          :key,
          :name,
          :description
        )
      end
      
      def serialize_action(action)
        {
          id: action.id,
          key: action.key,
          name: action.name,
          display_name: action.name,
          description: action.description,
          created_at: action.created_at,
          updated_at: action.updated_at
        }
      end
    end
  end
end

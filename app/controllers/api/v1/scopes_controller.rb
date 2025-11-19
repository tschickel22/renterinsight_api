# frozen_string_literal: true

module Api
  module V1
    class ScopesController < ApplicationController
      before_action :ensure_rbac_enabled
      before_action :set_scope, only: [:show, :update, :destroy]
      before_action :authorize_scope_management, except: [:index, :show]
      
      # GET /api/v1/scopes
      # List all scopes (system-level data)
      def index
        @scopes = Scope.order(:key)
        
        render json: {
          scopes: @scopes.map { |scope| serialize_scope(scope) }
        }
      end
      
      # GET /api/v1/scopes/:id
      # Show scope details
      def show
        render json: {
          scope: serialize_scope(@scope)
        }
      end
      
      # POST /api/v1/scopes
      # Create new scope (platform admin only)
      def create
        @scope = Scope.new(scope_params)
        
        if @scope.save
          render json: {
            scope: serialize_scope(@scope),
            message: 'Scope created successfully'
          }, status: :created
        else
          render json: {
            error: 'Failed to create scope',
            errors: @scope.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      # PATCH /api/v1/scopes/:id
      # Update scope (platform admin only)
      def update
        if @scope.update(scope_params)
          render json: {
            scope: serialize_scope(@scope),
            message: 'Scope updated successfully'
          }
        else
          render json: {
            error: 'Failed to update scope',
            errors: @scope.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/scopes/:id
      # Delete scope (platform admin only)
      def destroy
        @scope.destroy
        
        render json: {
          message: 'Scope deleted successfully'
        }
      end
      
      private
      
      def set_scope
        @scope = Scope.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Scope not found' }, status: :not_found
      end
      
      def ensure_rbac_enabled
        unless current_company.use_rbac_system
          render json: {
            error: 'RBAC system is not enabled for this company',
            message: 'Please contact your administrator to enable role-based access control'
          }, status: :forbidden
        end
      end
      
      def authorize_scope_management
        unless current_user.super_admin?
          render json: {
            error: 'Forbidden - Only platform administrators can manage scopes'
          }, status: :forbidden
        end
      end
      
      def scope_params
        params.require(:scope).permit(
          :key,
          :name,
          :description
        )
      end
      
      def serialize_scope(scope)
        {
          id: scope.id,
          key: scope.key,
          name: scope.name,
          display_name: scope.name,
          description: scope.description,
          created_at: scope.created_at,
          updated_at: scope.updated_at
        }
      end
    end
  end
end

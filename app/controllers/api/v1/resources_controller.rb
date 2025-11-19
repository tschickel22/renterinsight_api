# frozen_string_literal: true

module Api
  module V1
    class ResourcesController < ApplicationController
      before_action :ensure_rbac_enabled
      before_action :set_resource, only: [:show, :update, :destroy]
      before_action :authorize_resource_management, except: [:index, :show]
      
      # GET /api/v1/resources
      # List all resources (system-level data)
      def index
        @resources = Resource.active.order(:category, :name)
        
        render json: {
          resources: @resources.map { |resource| serialize_resource(resource) }
        }
      end
      
      # GET /api/v1/resources/:id
      # Show resource details
      def show
        render json: {
          resource: serialize_resource(@resource)
        }
      end
      
      # POST /api/v1/resources
      # Create new resource (platform admin only)
      def create
        @resource = Resource.new(resource_params)
        @resource.active = true
        
        if @resource.save
          render json: {
            resource: serialize_resource(@resource),
            message: 'Resource created successfully'
          }, status: :created
        else
          render json: {
            error: 'Failed to create resource',
            errors: @resource.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      # PATCH /api/v1/resources/:id
      # Update resource (platform admin only)
      def update
        if @resource.update(resource_params)
          render json: {
            resource: serialize_resource(@resource),
            message: 'Resource updated successfully'
          }
        else
          render json: {
            error: 'Failed to update resource',
            errors: @resource.errors.full_messages
          }, status: :unprocessable_entity
        end
      end
      
      # DELETE /api/v1/resources/:id
      # Soft delete resource (platform admin only)
      def destroy
        @resource.update(active: false)
        
        render json: {
          message: 'Resource deleted successfully'
        }
      end
      
      private
      
      def set_resource
        @resource = Resource.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Resource not found' }, status: :not_found
      end
      
      def ensure_rbac_enabled
        unless current_company.use_rbac_system
          render json: {
            error: 'RBAC system is not enabled for this company',
            message: 'Please contact your administrator to enable role-based access control'
          }, status: :forbidden
        end
      end
      
      def authorize_resource_management
        unless current_user.super_admin?
          render json: {
            error: 'Forbidden - Only platform administrators can manage resources'
          }, status: :forbidden
        end
      end
      
      def resource_params
        params.require(:resource).permit(
          :key,
          :name,
          :description,
          :category
        )
      end
      
      def serialize_resource(resource)
        {
          id: resource.id,
          key: resource.key,
          name: resource.name,
          display_name: resource.name,
          description: resource.description,
          category: resource.category,
          active: resource.active,
          created_at: resource.created_at,
          updated_at: resource.updated_at
        }
      end
    end
  end
end

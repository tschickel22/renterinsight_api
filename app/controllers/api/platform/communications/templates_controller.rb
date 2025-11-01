# frozen_string_literal: true

module Api
  module Platform
    module Communications
      class TemplatesController < ApplicationController
        before_action :set_template, only: [:show, :update, :destroy]
        
        # GET /api/platform/communications/templates
        def index
          templates = CommunicationTemplate.all
          
          # Apply filters
          templates = templates.where(company_id: params[:company_id]) if params[:company_id].present?
          templates = templates.where(template_type: params[:template_type]) if params[:template_type].present?
          templates = templates.where(channel: params[:channel]) if params[:channel].present?
          templates = templates.where(is_active: params[:is_active]) if params[:is_active].present?
          
          render json: {
            success: true,
            templates: templates.map { |t| serialize_template(t) }
          }
        end
        
        # GET /api/platform/communications/templates/:id
        def show
          render json: {
            success: true,
            template: serialize_template(@template)
          }
        end
        
        # POST /api/platform/communications/templates
        def create
          @template = CommunicationTemplate.new(template_params)
          
          if @template.save
            render json: {
              success: true,
              template: serialize_template(@template)
            }, status: :created
          else
            render json: {
              success: false,
              errors: @template.errors.full_messages
            }, status: :unprocessable_entity
          end
        end
        
        # PATCH/PUT /api/platform/communications/templates/:id
        def update
          if @template.update(template_params)
            render json: {
              success: true,
              template: serialize_template(@template)
            }
          else
            render json: {
              success: false,
              errors: @template.errors.full_messages
            }, status: :unprocessable_entity
          end
        end
        
        # DELETE /api/platform/communications/templates/:id
        def destroy
          @template.destroy
          render json: {
            success: true,
            message: 'Template deleted successfully'
          }
        end
        
        private
        
        def set_template
          @template = CommunicationTemplate.find(params[:id])
        rescue ActiveRecord::RecordNotFound
          render json: {
            success: false,
            error: 'Template not found'
          }, status: :not_found
        end
        
        def template_params
          params.require(:template).permit(
            :name,
            :template_type,
            :channel,
            :subject,
            :body,
            :is_active,
            :is_default,
            :company_id,
            :description
          )
        end
        
        def serialize_template(template)
          {
            id: template.id,
            name: template.name,
            templateType: template.template_type,
            channel: template.channel,
            subject: template.subject,
            body: template.body,
            isActive: template.is_active,
            isDefault: template.is_default,
            companyId: template.company_id,
            description: template.description,
            createdAt: template.created_at,
            updatedAt: template.updated_at
          }
        end
      end
    end
  end
end

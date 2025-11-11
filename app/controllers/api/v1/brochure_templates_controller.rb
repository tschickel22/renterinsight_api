# frozen_string_literal: true

module Api
  module V1
    class BrochureTemplatesController < ApplicationController
      before_action :require_admin, except: [:index, :show]
      before_action :set_template, only: [:show, :update, :destroy]

      # GET /api/v1/brochure-templates
      def index
        templates = BrochureTemplate.active.order(is_default: :desc, name: :asc)
        
        render json: {
          templates: templates.map { |t| template_json(t) }
        }
      end

      # GET /api/v1/brochure-templates/:id
      def show
        render json: { template: template_json(@template, detailed: true) }
      end

      # POST /api/v1/brochure-templates
      def create
        template_params_hash = params.require(:template).to_unsafe_h
        
        # Transform camelCase to snake_case
        transformed_params = {}
        template_params_hash.each do |key, value|
          snake_key = key.to_s.underscore
          transformed_params[snake_key] = value
        end
        
        safe_params = transformed_params.slice(
          'name',
          'description',
          'template_key',
          'theme',
          'preview_image',
          'template_data',
          'is_default',
          'active'
        )
        
        @template = BrochureTemplate.new(safe_params)
        
        if @template.save
          render json: { template: template_json(@template, detailed: true) }, status: :created
        else
          render json: { errors: @template.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error creating template: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # PATCH/PUT /api/v1/brochure-templates/:id
      def update
        template_params_hash = params.require(:template).to_unsafe_h
        
        # Transform camelCase to snake_case
        transformed_params = {}
        template_params_hash.each do |key, value|
          snake_key = key.to_s.underscore
          transformed_params[snake_key] = value
        end
        
        safe_params = transformed_params.slice(
          'name',
          'description',
          'template_key',
          'theme',
          'preview_image',
          'template_data',
          'is_default',
          'active'
        )
        
        if @template.update(safe_params)
          render json: { template: template_json(@template, detailed: true) }
        else
          render json: { errors: @template.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "Error updating template: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
        render json: { error: e.message }, status: :unprocessable_entity
      end

      # DELETE /api/v1/brochure-templates/:id
      def destroy
        if @template.is_default
          render json: { error: 'Cannot delete default templates' }, status: :forbidden
          return
        end
        
        # Soft delete by marking inactive
        @template.update(active: false)
        head :no_content
      end

      private

      def set_template
        @template = BrochureTemplate.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Template not found' }, status: :not_found
      end

      def require_admin
        unless current_user&.admin? || current_user&.super_admin?
          render json: { error: 'Admin access required' }, status: :forbidden
        end
      end

      def template_json(template, detailed: false)
        json = {
          id: template.id.to_s,
          name: template.name,
          description: template.description,
          templateKey: template.template_key,
          theme: template.theme,
          previewImage: template.preview_image,
          isDefault: template.is_default,
          active: template.active,
          createdAt: template.created_at,
          updatedAt: template.updated_at
        }
        
        json[:templateData] = template.template_data if detailed
        
        json
      end
    end
  end
end

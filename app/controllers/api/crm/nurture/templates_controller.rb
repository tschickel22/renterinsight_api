# frozen_string_literal: true

module Api
  module Crm
    module Nurture
      class TemplatesController < ApplicationController
        def index
          templates = Template.where(template_type: %w[email sms]).order(created_at: :desc)
          render json: templates.map { |t| template_json(t) }, status: :ok
        end

        def create
          template = Template.new(template_params)
          if template.save
            render json: template_json(template), status: :created
          else
            render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          template = Template.find(params[:id])
          if template.update(template_params)
            render json: template_json(template), status: :ok
          else
            render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          template = Template.find(params[:id])
          template.destroy!
          head :no_content
        end

        def bulk
          templates = params[:_json] || params[:templates] || []
          result = templates.map do |tpl_data|
            if tpl_data[:id]
              template = Template.find(tpl_data[:id])
              template.update!(template_params_from_hash(tpl_data))
            else
              template = Template.create!(template_params_from_hash(tpl_data))
            end
            template_json(template)
          end
          render json: result, status: :ok
        end

        private

        def template_params
          params.require(:template).permit(:name, :template_type, :subject, :body, :is_active)
        end

        def template_params_from_hash(hash)
          {
            name: hash[:name],
            template_type: hash[:type] || hash[:template_type],
            subject: hash[:subject],
            body: hash[:body],
            is_active: hash[:isActive] || hash[:is_active]
          }.compact
        end

        def template_json(template)
          {
            id: template.id,
            name: template.name,
            type: template.template_type,
            subject: template.subject,
            body: template.body,
            isActive: template.is_active,
            createdAt: template.created_at&.iso8601,
            updatedAt: template.updated_at&.iso8601
          }
        end
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module Crm
    module Nurture
      class TemplatesController < ApplicationController
        def index
          # Scope templates to current company for tenant isolation
          company = ::Company.find(current_company_id)
          templates = company.templates.where(template_type: %w[email sms]).order(created_at: :desc)
          render json: templates.map { |t| template_json(t) }, status: :ok
        end

        def create
          # Scope to current company
          company = ::Company.find(current_company_id)
          template = company.templates.new(template_params)
          
          # Handle file attachments if present
          if params[:attachments].present?
            params[:attachments].each do |file|
              template.attachments.attach(file)
            end
          end
          
          if template.save
            render json: template_json(template), status: :created
          else
            render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          # Scope to current company
          company = ::Company.find(current_company_id)
          template = company.templates.find(params[:id])
          
          # Handle file attachments if present
          if params[:attachments].present?
            params[:attachments].each do |file|
              template.attachments.attach(file)
            end
          end
          
          if template.update(template_params)
            render json: template_json(template), status: :ok
          else
            render json: { errors: template.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          # Scope to current company
          company = ::Company.find(current_company_id)
          template = company.templates.find(params[:id])
          template.destroy!
          head :no_content
        end
        
        # Delete a specific attachment
        def delete_attachment
          # Scope to current company
          company = ::Company.find(current_company_id)
          template = company.templates.find(params[:id])
          attachment = template.attachments.find(params[:attachment_id])
          attachment.purge
          render json: template_json(template), status: :ok
        end

        def bulk
          upsert_templates = params[:upsert] || []
          delete_ids = params[:delete] || []
          
          # Scope to current company
          company = ::Company.find(current_company_id)
          
          ActiveRecord::Base.transaction do
            # Delete templates (scoped to company)
            if delete_ids.any?
              company.templates.where(id: delete_ids).destroy_all
            end
            
            # Upsert templates
            upsert_templates.each do |tpl_data|
              if tpl_data[:id].present?
                # Update existing (scoped to company)
                template = company.templates.find(tpl_data[:id])
                template.update!(template_params_from_hash(tpl_data))
                
                # Handle attachments if present
                if tpl_data[:attachments].present?
                  tpl_data[:attachments].each do |file|
                    template.attachments.attach(file)
                  end
                end
              else
                # Create new (scoped to company)
                template = company.templates.create!(template_params_from_hash(tpl_data))
                
                # Handle attachments if present
                if tpl_data[:attachments].present?
                  tpl_data[:attachments].each do |file|
                    template.attachments.attach(file)
                  end
                end
              end
            end
          end
          
          # Return all templates (scoped to company)
          templates = company.templates.where(template_type: %w[email sms]).order(created_at: :desc)
          render json: templates.map { |t| template_json(t) }, status: :ok
        rescue StandardError => e
          Rails.logger.error("Template bulk error: #{e.message}")
          Rails.logger.error(e.backtrace.join("\n"))
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def template_params
          params.require(:template).permit(:name, :template_type, :subject, :body, :is_active)
        end

        def template_params_from_hash(hash)
          # template_type should be 'email' or 'sms' from the hash
          # type is a different field for categorization (welcome, follow_up, etc)
          {
            name: hash[:name],
            template_type: hash[:template_type],
            subject: hash[:subject],
            body: hash[:body],
            is_active: hash[:is_active].nil? ? true : hash[:is_active]
          }.compact
        end

        def template_json(template)
          attachments_data = []
          
          if template.attachments.attached?
            attachments_data = template.attachments.map do |attachment|
              {
                id: attachment.id,
                filename: attachment.filename.to_s,
                content_type: attachment.content_type,
                byte_size: attachment.byte_size,
                url: Rails.application.routes.url_helpers.rails_blob_path(attachment, only_path: true),
                created_at: attachment.created_at&.iso8601
              }
            end
          end
          
          {
            id: template.id,
            name: template.name,
            template_type: template.template_type,
            type: template.template_type,
            subject: template.subject,
            body: template.body,
            isActive: template.is_active,
            is_active: template.is_active,
            attachments: attachments_data,
            createdAt: template.created_at&.iso8601,
            updatedAt: template.updated_at&.iso8601
          }
        end
      end
    end
  end
end

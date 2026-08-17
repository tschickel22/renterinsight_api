# frozen_string_literal: true

module Api
  module Crm
    module Nurture
      class TemplatesController < ApplicationController
        include RbacAuthorization
        rbac_resource :crm

        before_action :set_company_scope

        def index
          templates = @company.templates.where(template_type: %w[email sms])
          templates = templates.where(template_type: params[:channel]) if params[:channel].present?
          templates = templates.where(category: params[:category]) if params[:category].present?
          templates = templates.where(source: params[:source]) if params[:source].present?
          templates = templates.where(usage: params[:usage]) if params[:usage].present?
          templates = templates.order(created_at: :desc)
          render json: templates.map { |t| template_json(t) }, status: :ok
        end

        def show
          template = @company.templates.find_by(id: params[:id])
          unless template
            render json: { error: 'Template not found' }, status: :not_found
            return
          end
          render json: template_json(template), status: :ok
        end

        def create
          template = @company.templates.new(template_params)
          
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
          template = @company.templates.find_by(id: params[:id])
          unless template
            render json: { error: 'Template not found' }, status: :not_found
            return
          end
          
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
          template = @company.templates.find_by(id: params[:id])
          unless template
            render json: { error: 'Template not found' }, status: :not_found
            return
          end
          
          # Nullify template references in nurture_steps first to avoid FK violation
          NurtureStep.where(template_id: template.id).update_all(template_id: nil)
          template.destroy!
          head :no_content
        end
        
        # Delete a specific attachment
        def delete_attachment
          template = @company.templates.find_by(id: params[:id])
          unless template
            render json: { error: 'Template not found' }, status: :not_found
            return
          end
          
          attachment = template.attachments.find_by(id: params[:attachment_id])
          unless attachment
            render json: { error: 'Attachment not found' }, status: :not_found
            return
          end
          
          attachment.purge
          render json: template_json(template), status: :ok
        end

        def bulk
          upsert_templates = params[:upsert] || []
          delete_ids = params[:delete] || []
          
          ActiveRecord::Base.transaction do
            # Delete templates (scoped to company)
            if delete_ids.any?
              # Nullify template references in nurture_steps first to avoid FK violation
              NurtureStep.where(template_id: delete_ids).update_all(template_id: nil)
              @company.templates.where(id: delete_ids).destroy_all
            end
            
            # Upsert templates
            upsert_templates.each do |tpl_data|
              if tpl_data[:id].present?
                # Update existing (scoped to company)
                template = @company.templates.find_by(id: tpl_data[:id])
                next unless template # Skip if not found in this company
                
                template.update!(template_params_from_hash(tpl_data))
                
                # Handle attachments if present
                if tpl_data[:attachments].present?
                  tpl_data[:attachments].each do |file|
                    template.attachments.attach(file)
                  end
                end
              else
                # Create new (scoped to company)
                template = @company.templates.create!(template_params_from_hash(tpl_data))
                
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
          templates = @company.templates.where(template_type: %w[email sms]).order(created_at: :desc)
          render json: templates.map { |t| template_json(t) }, status: :ok
        rescue StandardError => e
          Rails.logger.error("Template bulk error: #{e.message}")
          Rails.logger.error(e.backtrace.join("\n"))
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def set_company_scope
          unless current_user
            Rails.logger.error "🚫 [Nurture::TemplatesController] No authenticated user found"
            render json: { error: 'Authentication required' }, status: :unauthorized
            return
          end
          
          company_id = current_company_id
          
          unless company_id.present?
            Rails.logger.error "🚫 [Nurture::TemplatesController] No company context available"
            render json: { error: 'No company context' }, status: :forbidden
            return
          end
          
          @company = ::Company.find_by(id: company_id)
          
          if @company.nil?
            Rails.logger.error "🚫 [Nurture::TemplatesController] Company #{company_id} not found"
            render json: { error: 'Company not found' }, status: :not_found
            return
          end
          
          Rails.logger.info "✅ [Nurture::TemplatesController] Company scope set: #{@company.name} (ID: #{@company.id})"
        end

        def template_params
          params.require(:template).permit(:name, :template_type, :subject, :body, :is_active, :category, :source, :usage)
        end

        def template_params_from_hash(hash)
          {
            name: hash[:name],
            template_type: hash[:template_type],
            subject: hash[:subject],
            body: hash[:body],
            category: hash[:category],
            source: hash[:source],
            usage: hash[:usage],
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

          # Find nurture sequences that use this template (via nurture_steps)
          using_sequences = NurtureSequence
            .joins(:nurture_steps)
            .where(nurture_steps: { template_id: template.id })
            .distinct
            .pluck(:name)
          
          {
            id: template.id,
            name: template.name,
            template_type: template.template_type,
            type: template.template_type,
            subject: template.subject,
            body: template.body,
            category: template.category,
            source: template.source,
            # Nurture sequence step vs one-off send. Separate from category, which is
            # topical. See the AddUsageToTemplates migration.
            usage: template.usage,
            isActive: template.is_active,
            is_active: template.is_active,
            attachments: attachments_data,
            usageCount: using_sequences.size,
            usedInSequences: using_sequences,
            createdAt: template.created_at&.iso8601,
            updatedAt: template.updated_at&.iso8601
          }
        end
      end
    end
  end
end

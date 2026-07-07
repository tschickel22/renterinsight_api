# frozen_string_literal: true

module Api
  module Crm
    module Nurture
      class SequencesController < ApplicationController
        include RbacAuthorization
        rbac_resource :crm

        before_action :set_company_scope

        def index
          sequences = @company.nurture_sequences.includes(:nurture_steps).order(created_at: :desc)
          render json: sequences.map { |s| sequence_json(s) }, status: :ok
        rescue => e
          Rails.logger.error "Error in sequences#index: #{e.message}\n#{e.backtrace.join("\n")}"
          render json: { error: e.message }, status: :internal_server_error
        end

        def show
          sequence = @company.nurture_sequences.find_by(id: params[:id])
          unless sequence
            render json: { error: 'Sequence not found' }, status: :not_found
            return
          end
          render json: sequence_json(sequence), status: :ok
        end

        def create
          sequence = @company.nurture_sequences.new(sequence_params)
          if sequence.save
            render json: sequence_json(sequence), status: :created
          else
            render json: { errors: sequence.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          sequence = @company.nurture_sequences.find_by(id: params[:id])
          unless sequence
            render json: { error: 'Sequence not found' }, status: :not_found
            return
          end
          
          ActiveRecord::Base.transaction do
            # Update sequence attributes
            sequence.name = params[:name] if params[:name].present?
            sequence.description = params[:description] if params.key?(:description)
            sequence.is_active = params[:is_active] != false if params.key?(:is_active)
            sequence.is_active = params[:isActive] != false if params.key?(:isActive)
            
            sequence.save!
            
            # ✅ FIX: Handle steps array if provided
            if params[:steps].present?
              Rails.logger.info "[Nurture] Updating #{params[:steps].length} steps for sequence #{sequence.id}"
              
              # Delete existing steps not in the new list
              existing_step_ids = params[:steps].map { |s| s[:id] }.compact
              deleted_count = sequence.nurture_steps.where.not(id: existing_step_ids).destroy_all.count
              Rails.logger.info "[Nurture] Deleted #{deleted_count} old steps"
              
              # Create or update steps
              params[:steps].each_with_index do |step_data, index|
                step = if step_data[:id].present?
                  sequence.nurture_steps.find_or_initialize_by(id: step_data[:id])
                else
                  sequence.nurture_steps.new
                end
                
                step.step_type = step_data[:step_type] || step_data[:type] || 'email'
                step.position = step_data[:position] || step_data[:order] || index
                step.wait_days = step_data[:wait_days] || step_data[:waitDays] || 0
                step.subject = step_data[:subject] || ''
                step.body = step_data[:body] || ''
                step.template_id = step_data[:template_id] || step_data[:templateId]
                # Optional per-step inventory filters. Empty statuses array
                # keeps today's [available, available_to_order] default; the
                # require_images flag defaults to false so untouched steps
                # keep including image-less units in their inventory picks.
                if step_data.key?(:inventory_statuses) || step_data.key?(:inventoryStatuses)
                  raw = step_data[:inventory_statuses] || step_data[:inventoryStatuses]
                  step.inventory_statuses = Array(raw).map(&:to_s).reject(&:blank?)
                end
                if step_data.key?(:inventory_require_images) || step_data.key?(:inventoryRequireImages)
                  raw = step_data[:inventory_require_images]
                  raw = step_data[:inventoryRequireImages] if raw.nil?
                  step.inventory_require_images = ActiveModel::Type::Boolean.new.cast(raw)
                end

                step.save!
                
                Rails.logger.info "[Nurture] Saved step #{step.id}: type=#{step.step_type}, wait_days=#{step.wait_days}, template_id=#{step.template_id}"
              end
            end
            
            render json: sequence_json(sequence.reload), status: :ok
          end
        rescue => e
          Rails.logger.error "[Nurture] Update failed: #{e.message}\n#{e.backtrace.join("\n")}"
          render json: { errors: [e.message] }, status: :unprocessable_entity
        end

        def destroy
          sequence = @company.nurture_sequences.find_by(id: params[:id])
          unless sequence
            render json: { error: 'Sequence not found' }, status: :not_found
            return
          end
          
          sequence.destroy!
          head :no_content
        end

        def bulk
          upsert_data = params[:upsert] || []
          delete_ids = params[:delete] || []
          
          results = []
          
          ActiveRecord::Base.transaction do
            # Handle deletions (scoped to company)
            delete_ids.each do |id|
              sequence = @company.nurture_sequences.find_by(id: id)
              sequence&.destroy
            end
            
            # Handle upserts (create or update)
            upsert_data.each do |seq_data|
              sequence = if seq_data[:id].present?
                @company.nurture_sequences.find_or_initialize_by(id: seq_data[:id])
              else
                @company.nurture_sequences.new
              end
              
              # Update sequence attributes
              sequence.name = seq_data[:name] if seq_data[:name].present?
              sequence.description = seq_data[:description] if seq_data.key?(:description)
              sequence.is_active = seq_data[:is_active] != false
              sequence.company_id = @company.id # Ensure company scope
              
              sequence.save!
              
              # Handle steps if provided
              if seq_data[:steps].present?
                # Delete existing steps not in the new list
                existing_step_ids = seq_data[:steps].map { |s| s[:id] }.compact
                sequence.nurture_steps.where.not(id: existing_step_ids).destroy_all
                
                # Create or update steps
                seq_data[:steps].each do |step_data|
                  step = if step_data[:id].present?
                    sequence.nurture_steps.find_or_initialize_by(id: step_data[:id])
                  else
                    sequence.nurture_steps.new
                  end
                  
                  step.step_type = step_data[:step_type] if step_data[:step_type].present?
                  step.position = step_data[:position] if step_data[:position].present?
                  step.wait_days = step_data[:wait_days] || 0
                  step.subject = step_data[:subject] if step_data.key?(:subject)
                  step.body = step_data[:body] if step_data.key?(:body)
                  step.template_id = step_data[:template_id] if step_data.key?(:template_id)
                  if step_data.key?(:inventory_statuses) || step_data.key?(:inventoryStatuses)
                    raw = step_data[:inventory_statuses] || step_data[:inventoryStatuses]
                    step.inventory_statuses = Array(raw).map(&:to_s).reject(&:blank?)
                  end
                  if step_data.key?(:inventory_require_images) || step_data.key?(:inventoryRequireImages)
                    raw = step_data[:inventory_require_images]
                    raw = step_data[:inventoryRequireImages] if raw.nil?
                    step.inventory_require_images = ActiveModel::Type::Boolean.new.cast(raw)
                  end

                  step.save!
                end
              end
              
              results << sequence_json(sequence.reload)
            end
          end
          
          render json: results, status: :ok
        rescue => e
          Rails.logger.error "Bulk operation failed: #{e.message}\n#{e.backtrace.join("\n")}"
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def set_company_scope
          unless current_user
            Rails.logger.error "🚫 [Nurture::SequencesController] No authenticated user found"
            render json: { error: 'Authentication required' }, status: :unauthorized
            return
          end
          
          company_id = current_company_id
          
          unless company_id.present?
            Rails.logger.error "🚫 [Nurture::SequencesController] No company context available"
            render json: { error: 'No company context' }, status: :forbidden
            return
          end
          
          @company = ::Company.find_by(id: company_id)
          
          if @company.nil?
            Rails.logger.error "🚫 [Nurture::SequencesController] Company #{company_id} not found"
            render json: { error: 'Company not found' }, status: :not_found
            return
          end
          
          Rails.logger.info "✅ [Nurture::SequencesController] Company scope set: #{@company.name} (ID: #{@company.id})"
        end

        def sequence_params
          params.require(:sequence).permit(:name, :description, :is_active)
        end

        def sequence_json(sequence)
          steps = sequence.nurture_steps.order(:position).to_a
          
          {
            id: sequence.id,
            name: sequence.name || '',
            description: sequence.description || '',
            is_active: sequence.is_active,
            isActive: sequence.is_active,
            nurture_steps: steps.map { |s| step_json(s) },
            steps: steps.map { |s| step_json(s) },
            created_at: sequence.created_at&.iso8601,
            updated_at: sequence.updated_at&.iso8601
          }
        rescue => e
          Rails.logger.error "Error serializing sequence #{sequence.id}: #{e.message}"
          {
            id: sequence.id,
            name: sequence.name || '',
            description: sequence.description || '',
            is_active: true,
            isActive: true,
            nurture_steps: [],
            steps: [],
            created_at: sequence.created_at&.iso8601,
            updated_at: sequence.updated_at&.iso8601
          }
        end

        def step_json(step)
          {
            id: step.id,
            step_type: step.step_type || 'email',
            type: step.step_type || 'email',
            subject: step.subject || '',
            body: step.body || '',
            wait_days: step.wait_days || 0,
            waitDays: step.wait_days || 0,
            position: step.position || 0,
            order: step.position || 0,
            template_id: step.template_id,
            templateId: step.template_id,
            nurture_sequence_id: step.nurture_sequence_id,
            nurtureSequenceId: step.nurture_sequence_id
          }
        end
      end
    end
  end
end

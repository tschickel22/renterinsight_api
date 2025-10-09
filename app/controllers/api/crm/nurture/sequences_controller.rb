# frozen_string_literal: true

module Api
  module Crm
    module Nurture
      class SequencesController < ApplicationController
        def index
          sequences = NurtureSequence.includes(:nurture_steps).order(created_at: :desc)
          render json: sequences.map { |s| sequence_json(s) }, status: :ok
        rescue => e
          Rails.logger.error "Error in sequences#index: #{e.message}\n#{e.backtrace.join("\n")}"
          render json: { error: e.message }, status: :internal_server_error
        end

        def create
          sequence = NurtureSequence.new(sequence_params)
          if sequence.save
            render json: sequence_json(sequence), status: :created
          else
            render json: { errors: sequence.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          sequence = NurtureSequence.find(params[:id])
          if sequence.update(sequence_params)
            render json: sequence_json(sequence), status: :ok
          else
            render json: { errors: sequence.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          sequence = NurtureSequence.find(params[:id])
          sequence.destroy!
          head :no_content
        end

        def bulk
          upsert_data = params[:upsert] || []
          delete_ids = params[:delete] || []
          
          results = []
          
          ActiveRecord::Base.transaction do
            # Handle deletions
            delete_ids.each do |id|
              sequence = NurtureSequence.find_by(id: id)
              sequence&.destroy
            end
            
            # Handle upserts (create or update)
            upsert_data.each do |seq_data|
              sequence = if seq_data[:id].present?
                NurtureSequence.find_or_initialize_by(id: seq_data[:id])
              else
                NurtureSequence.new
              end
              
              # Update sequence attributes
              sequence.name = seq_data[:name] if seq_data[:name].present?
              sequence.description = seq_data[:description] if seq_data.key?(:description)
              sequence.is_active = seq_data[:is_active] != false
              
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

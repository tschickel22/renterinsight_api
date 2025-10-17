# frozen_string_literal: true

module Api
  module Crm
    module Nurture
      class EnrollmentsController < ApplicationController
        def index
          # Support filtering by lead_id, entity_type, or entity_id
          lead_ids = params[:lead_id]
          entity_type = params[:entity_type]
          entity_id = params[:entity_id]
          
          enrollments = NurtureEnrollment.all
          
          # Filter by entity_type
          if entity_type.present?
            enrollments = enrollments.where(enrollable_type: entity_type)
            enrollments = enrollments.where(enrollable_id: entity_id) if entity_id.present?
          # Backward compatibility: filter by lead_id
          elsif lead_ids.present?
            enrollments = enrollments.for_lead(lead_ids)
          end
          
          enrollments = enrollments.includes(:nurture_sequence).order(created_at: :desc)
          
          render json: enrollments.map { |e| enrollment_json(e) }, status: :ok
        rescue => e
          Rails.logger.error "Error in enrollments#index: #{e.message}\n#{e.backtrace.join("\n")}"
          render json: { error: e.message }, status: :internal_server_error
        end

        def create
          # Determine entity from params
          entity_type, entity_id = extract_entity_params
          
          # Pause any existing running enrollments for this entity
          if entity_type && entity_id
            NurtureEnrollment.for_entity(entity_type, entity_id)
              .where(status: 'running')
              .update_all(status: 'paused')
          end
          
          enrollment = NurtureEnrollment.new(enrollment_params)
          if enrollment.save
            # Start processing if status is running
            if enrollment.status == 'running'
              ProcessNurtureStepJob.perform_later(enrollment.id) if defined?(ProcessNurtureStepJob)
            end
            render json: enrollment_json(enrollment), status: :created
          else
            render json: { errors: enrollment.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          enrollment = NurtureEnrollment.find(params[:id])
          
          # If setting to running, pause other enrollments for this entity
          if params.dig(:enrollment, :status) == 'running' || params[:status] == 'running'
            entity_type = enrollment.entity_type
            entity_id = enrollment.entity_id
            
            if entity_type && entity_id
              NurtureEnrollment.for_entity(entity_type, entity_id)
                .where(status: 'running')
                .where.not(id: enrollment.id)
                .update_all(status: 'paused')
            end
          end
          
          if enrollment.update(enrollment_params)
            # Resume processing if status changed to running
            if enrollment.status == 'running' && enrollment.status_previously_was != 'running'
              ProcessNurtureStepJob.perform_later(enrollment.id) if defined?(ProcessNurtureStepJob)
            end
            render json: enrollment_json(enrollment), status: :ok
          else
            render json: { errors: enrollment.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def destroy
          enrollment = NurtureEnrollment.find(params[:id])
          enrollment.destroy!
          head :no_content
        end

        def bulk
          upsert_data = params[:upsert] || []
          delete_ids = params[:delete] || []
          
          results = []
          
          ActiveRecord::Base.transaction do
            # Handle deletions
            delete_ids.each do |id|
              enrollment = NurtureEnrollment.find_by(id: id)
              enrollment&.destroy
            end
            
            # Handle upserts (create or update)
            upsert_data.each do |enr_data|
              enrollment = if enr_data[:id].present?
                NurtureEnrollment.find_or_initialize_by(id: enr_data[:id])
              else
                NurtureEnrollment.new
              end
              
              # Extract entity info (polymorphic or legacy lead_id)
              entity_type = enr_data[:entity_type] || enr_data[:entityType]
              entity_id = enr_data[:entity_id] || enr_data[:entityId]
              lead_id = enr_data[:lead_id] || enr_data[:leadId]
              
              # Set polymorphic or legacy association
              if entity_type.present? && entity_id.present?
                enrollment.enrollable_type = entity_type
                enrollment.enrollable_id = entity_id
              elsif lead_id.present?
                # Backward compatibility: set both lead_id and polymorphic
                enrollment.lead_id = lead_id
                enrollment.enrollable_type = 'Lead'
                enrollment.enrollable_id = lead_id
              end
              
              # Set other fields
              sequence_id = enr_data[:nurture_sequence_id] || enr_data[:nurtureSequenceId] || enr_data[:sequenceId]
              status = enr_data[:status] || 'running'
              
              enrollment.nurture_sequence_id = sequence_id if sequence_id
              enrollment.status = status
              enrollment.current_step_index = enr_data[:current_step_index] || enr_data[:currentStepIndex] || 0
              
              # If setting to running, pause other enrollments for this entity
              if status == 'running'
                etype = enrollment.entity_type
                eid = enrollment.entity_id
                
                if etype && eid
                  NurtureEnrollment.for_entity(etype, eid)
                    .where(status: 'running')
                    .where.not(id: enrollment.id)
                    .update_all(status: 'paused')
                end
              end
              
              enrollment.save!
              
              # Start processing if status is running
              if enrollment.status == 'running'
                ProcessNurtureStepJob.perform_later(enrollment.id) if defined?(ProcessNurtureStepJob)
              end
              
              results << enrollment_json(enrollment)
            end
          end
          
          render json: results, status: :ok
        rescue => e
          Rails.logger.error "Bulk enrollment operation failed: #{e.message}\n#{e.backtrace.join("\n")}"
          render json: { error: e.message }, status: :unprocessable_entity
        end

        private

        def enrollment_params
          params.require(:enrollment).permit(
            :lead_id, 
            :nurture_sequence_id, 
            :status, 
            :current_step_index,
            :enrollable_type,
            :enrollable_id
          )
        end

        def extract_entity_params
          entity_type = params.dig(:enrollment, :entity_type) || 
                       params.dig(:enrollment, :entityType) ||
                       params[:entity_type] ||
                       params[:entityType]
          
          entity_id = params.dig(:enrollment, :entity_id) || 
                     params.dig(:enrollment, :entityId) ||
                     params[:entity_id] ||
                     params[:entityId]
          
          # Fallback to lead_id for backward compatibility
          if entity_type.blank? && entity_id.blank?
            lead_id = params.dig(:enrollment, :lead_id) || 
                     params.dig(:enrollment, :leadId) ||
                     params[:lead_id] ||
                     params[:leadId]
            
            if lead_id.present?
              entity_type = 'Lead'
              entity_id = lead_id
            end
          end
          
          [entity_type, entity_id]
        end

        def enrollment_json(enrollment)
          begin
            entity = enrollment.entity rescue nil
            entity_name = if entity
              entity.respond_to?(:name) ? entity.name : entity.try(:first_name)
            else
              nil
            end
          rescue => e
            Rails.logger.error "Error loading entity for enrollment #{enrollment.id}: #{e.message}"
            entity = nil
            entity_name = nil
          end
          
          {
            id: enrollment.id,
            # Polymorphic fields
            entity_type: enrollment.entity_type,
            entityType: enrollment.entity_type,
            entity_id: enrollment.entity_id,
            entityId: enrollment.entity_id,
            # Backward compatibility fields
            lead_id: enrollment.lead_id,
            leadId: enrollment.lead_id,
            # Entity details
            entity_name: entity_name,
            entityName: entity_name,
            # Sequence info
            nurture_sequence_id: enrollment.nurture_sequence_id,
            nurtureSequenceId: enrollment.nurture_sequence_id,
            sequenceId: enrollment.nurture_sequence_id,
            sequence_name: enrollment.nurture_sequence&.name,
            sequenceName: enrollment.nurture_sequence&.name,
            # Status
            status: enrollment.status || 'idle',
            current_step_index: enrollment.current_step_index || 0,
            currentStepIndex: enrollment.current_step_index || 0,
            # Timestamps
            created_at: enrollment.created_at&.iso8601,
            updated_at: enrollment.updated_at&.iso8601
          }
        end
      end
    end
  end
end

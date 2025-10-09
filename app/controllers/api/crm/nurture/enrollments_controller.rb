# frozen_string_literal: true

module Api
  module Crm
    module Nurture
      class EnrollmentsController < ApplicationController
        def index
          # Support filtering by lead_id
          lead_ids = params[:lead_id]
          
          enrollments = if lead_ids.present?
            NurtureEnrollment.includes(:lead, :nurture_sequence)
              .where(lead_id: lead_ids)
              .order(created_at: :desc)
          else
            NurtureEnrollment.includes(:lead, :nurture_sequence).order(created_at: :desc)
          end
          
          render json: enrollments.map { |e| enrollment_json(e) }, status: :ok
        rescue => e
          Rails.logger.error "Error in enrollments#index: #{e.message}\n#{e.backtrace.join("\n")}"
          render json: { error: e.message }, status: :internal_server_error
        end

        def create
          # Pause any existing running enrollments for this lead
          lead_id = enrollment_params[:lead_id]
          NurtureEnrollment.where(lead_id: lead_id, status: 'running').update_all(status: 'paused')
          
          enrollment = NurtureEnrollment.new(enrollment_params)
          if enrollment.save
            # Start processing if status is running
            if enrollment.status == 'running'
              ProcessNurtureStepJob.perform_later(enrollment.id)
            end
            render json: enrollment_json(enrollment), status: :created
          else
            render json: { errors: enrollment.errors.full_messages }, status: :unprocessable_entity
          end
        end

        def update
          enrollment = NurtureEnrollment.find(params[:id])
          
          # If setting to running, pause other enrollments for this lead
          if params.dig(:enrollment, :status) == 'running' || params[:status] == 'running'
            NurtureEnrollment.where(lead_id: enrollment.lead_id, status: 'running')
              .where.not(id: enrollment.id)
              .update_all(status: 'paused')
          end
          
          if enrollment.update(enrollment_params)
            # Resume processing if status changed to running
            if enrollment.status == 'running' && enrollment.status_previously_was != 'running'
              ProcessNurtureStepJob.perform_later(enrollment.id)
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
              lead_id = enr_data[:lead_id] || enr_data[:leadId]
              sequence_id = enr_data[:nurture_sequence_id] || enr_data[:nurtureSequenceId] || enr_data[:sequenceId]
              status = enr_data[:status] || 'running'
              
              enrollment = if enr_data[:id].present?
                NurtureEnrollment.find_or_initialize_by(id: enr_data[:id])
              else
                NurtureEnrollment.new
              end
              
              # If setting to running, pause other enrollments for this lead
              if status == 'running' && lead_id
                NurtureEnrollment.where(lead_id: lead_id, status: 'running')
                  .where.not(id: enrollment.id)
                  .update_all(status: 'paused')
              end
              
              enrollment.lead_id = lead_id if lead_id
              enrollment.nurture_sequence_id = sequence_id if sequence_id
              enrollment.status = status
              enrollment.current_step_index = enr_data[:current_step_index] || enr_data[:currentStepIndex] || 0
              
              enrollment.save!
              
              # Start processing if status is running and it's a new enrollment or status changed
              if enrollment.status == 'running'
                ProcessNurtureStepJob.perform_later(enrollment.id)
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
          params.require(:enrollment).permit(:lead_id, :nurture_sequence_id, :status, :current_step_index)
        end

        def enrollment_json(enrollment)
          {
            id: enrollment.id,
            lead_id: enrollment.lead_id,
            leadId: enrollment.lead_id,
            nurture_sequence_id: enrollment.nurture_sequence_id,
            nurtureSequenceId: enrollment.nurture_sequence_id,
            sequenceId: enrollment.nurture_sequence_id,
            status: enrollment.status || 'idle',
            current_step_index: enrollment.current_step_index || 0,
            currentStepIndex: enrollment.current_step_index || 0,
            created_at: enrollment.created_at&.iso8601,
            updated_at: enrollment.updated_at&.iso8601
          }
        end
      end
    end
  end
end

# frozen_string_literal: true

module Api
  module Crm
    module Nurture
      class EnrollmentsController < ApplicationController
        include RbacAuthorization
        rbac_resource :crm

        before_action :set_company_scope

        def index
          # Support filtering by lead_id, entity_type, or entity_id
          lead_ids = params[:lead_id]
          entity_type = params[:entity_type]
          entity_id = params[:entity_id]
          
          # Scope enrollments to this company
          enrollments = NurtureEnrollment.for_company(@company.id)
          
          # Filter by entity_type
          if entity_type.present?
            enrollments = enrollments.where(enrollable_type: entity_type)
            enrollments = enrollments.where(enrollable_id: entity_id) if entity_id.present?
          # Backward compatibility: filter by lead_id
          elsif lead_ids.present?
            # Verify lead belongs to company
            lead = @company.leads.find_by(id: lead_ids)
            if lead
              enrollments = enrollments.for_lead(lead_ids)
            else
              enrollments = enrollments.none
            end
          end
          
          enrollments = enrollments.includes(:nurture_sequence).order(created_at: :desc)
          
          render json: enrollments.map { |e| enrollment_json(e) }, status: :ok
        rescue => e
          Rails.logger.error "Error in enrollments#index: #{e.message}\n#{e.backtrace.join("\n")}"
          render json: { error: e.message }, status: :internal_server_error
        end

        def show
          enrollment = NurtureEnrollment.for_company(@company.id).find_by(id: params[:id])
          unless enrollment
            render json: { error: 'Enrollment not found' }, status: :not_found
            return
          end
          render json: enrollment_json(enrollment), status: :ok
        end

        def create
          # Determine entity from params
          entity_type, entity_id = extract_entity_params
          
          # Validate entity belongs to company
          unless validate_entity_ownership(entity_type, entity_id)
            render json: { error: 'Entity not found or access denied' }, status: :not_found
            return
          end
          
          # Pause any existing running enrollments for this entity
          if entity_type && entity_id
            NurtureEnrollment.for_company(@company.id)
              .for_entity(entity_type, entity_id)
              .where(status: 'running')
              .update_all(status: 'paused')
          end
          
          enrollment = NurtureEnrollment.new(enrollment_params)
          enrollment.company_id = @company.id
          
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
          enrollment = NurtureEnrollment.for_company(@company.id).find_by(id: params[:id])
          unless enrollment
            render json: { error: 'Enrollment not found' }, status: :not_found
            return
          end
          
          # If setting to running, pause other enrollments for this entity
          if params.dig(:enrollment, :status) == 'running' || params[:status] == 'running'
            entity_type = enrollment.entity_type
            entity_id = enrollment.entity_id
            
            if entity_type && entity_id
              NurtureEnrollment.for_company(@company.id)
                .for_entity(entity_type, entity_id)
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
          enrollment = NurtureEnrollment.for_company(@company.id).find_by(id: params[:id])
          unless enrollment
            render json: { error: 'Enrollment not found' }, status: :not_found
            return
          end
          
          enrollment.destroy!
          head :no_content
        end

        def bulk
          upsert_data = params[:upsert] || []
          delete_ids = params[:delete] || []
          
          results = []
          
          ActiveRecord::Base.transaction do
            # Handle deletions (scoped to company)
            delete_ids.each do |id|
              enrollment = NurtureEnrollment.for_company(@company.id).find_by(id: id)
              enrollment&.destroy
            end
            
            # Handle upserts (create or update)
            upsert_data.each do |enr_data|
              enrollment = if enr_data[:id].present?
                NurtureEnrollment.for_company(@company.id).find_or_initialize_by(id: enr_data[:id])
              else
                NurtureEnrollment.new(company_id: @company.id)
              end
              
              # Extract entity info (polymorphic or legacy lead_id)
              entity_type = enr_data[:entity_type] || enr_data[:entityType]
              entity_id = enr_data[:entity_id] || enr_data[:entityId]
              lead_id = enr_data[:lead_id] || enr_data[:leadId]
              
              # Validate entity ownership
              if entity_type.present? && entity_id.present?
                unless validate_entity_ownership(entity_type, entity_id)
                  next # Skip this enrollment if entity not owned
                end
                enrollment.enrollable_type = entity_type
                enrollment.enrollable_id = entity_id
              elsif lead_id.present?
                unless @company.leads.exists?(id: lead_id)
                  next # Skip if lead not owned
                end
                enrollment.lead_id = lead_id
                enrollment.enrollable_type = 'Lead'
                enrollment.enrollable_id = lead_id
              end
              
              # Set other fields
              sequence_id = enr_data[:nurture_sequence_id] || enr_data[:nurtureSequenceId] || enr_data[:sequenceId]
              status = enr_data[:status] || 'running'
              
              # Validate sequence belongs to company
              if sequence_id.present? && !@company.nurture_sequences.exists?(id: sequence_id)
                next # Skip if sequence not owned
              end
              
              enrollment.nurture_sequence_id = sequence_id if sequence_id
              enrollment.status = status
              enrollment.current_step_index = enr_data[:current_step_index] || enr_data[:currentStepIndex] || 0
              enrollment.company_id = @company.id
              
              # If setting to running, pause other enrollments for this entity
              if status == 'running'
                etype = enrollment.entity_type
                eid = enrollment.entity_id
                
                if etype && eid
                  NurtureEnrollment.for_company(@company.id)
                    .for_entity(etype, eid)
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

        # POST /api/crm/nurture/enrollments/:id/trigger_step
        # Manually trigger the next step (for testing)
        def trigger_step
          enrollment = NurtureEnrollment.for_company(@company.id).find_by(id: params[:id])
          unless enrollment
            render json: { error: 'Enrollment not found' }, status: :not_found
            return
          end

          unless enrollment.status == 'running'
            render json: { error: 'Enrollment must be running to trigger steps' }, status: :unprocessable_entity
            return
          end

          # Trigger the job immediately (bypass wait delay)
          if defined?(ProcessNurtureStepJob)
            ProcessNurtureStepJob.perform_now(enrollment.id)
            render json: { message: 'Step triggered', enrollment: enrollment_json(enrollment) }, status: :ok
          else
            render json: { error: 'Job processor not available' }, status: :internal_server_error
          end
        rescue => e
          Rails.logger.error "Failed to trigger step: #{e.message}\n#{e.backtrace.join("\n")}"
          render json: { error: e.message }, status: :internal_server_error
        end

        private

        def set_company_scope
          unless current_user
            Rails.logger.error "🚫 [Nurture::EnrollmentsController] No authenticated user found"
            render json: { error: 'Authentication required' }, status: :unauthorized
            return
          end
          
          company_id = current_company_id
          
          unless company_id.present?
            Rails.logger.error "🚫 [Nurture::EnrollmentsController] No company context available"
            render json: { error: 'No company context' }, status: :forbidden
            return
          end
          
          @company = ::Company.find_by(id: company_id)
          
          if @company.nil?
            Rails.logger.error "🚫 [Nurture::EnrollmentsController] Company #{company_id} not found"
            render json: { error: 'Company not found' }, status: :not_found
            return
          end
          
          Rails.logger.info "✅ [Nurture::EnrollmentsController] Company scope set: #{@company.name} (ID: #{@company.id})"
        end

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

        def validate_entity_ownership(entity_type, entity_id)
          return false unless entity_type && entity_id
          
          case entity_type
          when 'Lead'
            @company.leads.exists?(id: entity_id)
          when 'Account'
            @company.accounts.exists?(id: entity_id) if @company.respond_to?(:accounts)
          when 'Contact'
            @company.contacts.exists?(id: entity_id) if @company.respond_to?(:contacts)
          else
            false
          end
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

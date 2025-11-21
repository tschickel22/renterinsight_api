# frozen_string_literal: true
module Api
  module Crm
    class RemindersController < ApplicationController
      include RbacAuthorization
      rbac_resource :crm,
        read_actions: [:index],
        create_actions: [:create],
        update_actions: [:update, :complete],
        delete_actions: [:destroy]

      before_action :set_company_scope
      before_action :set_lead, only: [:index, :create, :update]
      before_action :set_reminder, only: [:update, :complete, :destroy]

      def index
        reminders = @lead.reminders.order(due_date: :asc)
        render json: reminders.map { |r| reminder_json(r) }, status: :ok
      end

      def create
        data = extract_reminder_params
        reminder = @lead.reminders.build(data)
        # Use current_user for proper tenant isolation
        reminder.user_id ||= current_user&.id
        
        if reminder.save
          render json: reminder_json(reminder), status: :created
        else
          render json: { error: 'Failed to create reminder', errors: reminder.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[RemindersController#create] #{e.class}: #{e.message}"
        render json: { error: 'Server error creating reminder', message: e.message }, status: :internal_server_error
      end

      def update
        payload = extract_reminder_params
        raw = params[:reminder].respond_to?(:to_unsafe_h) ? params[:reminder].to_unsafe_h : (params[:reminder] || {})
        uid = raw['user_id'] || raw[:user_id]
        
        if uid && uid.to_s.strip != ''
          # Verify user belongs to same company for security
          if @company.users.exists?(uid.to_i)
            payload[:user_id] = uid.to_i
          else
            payload[:user_id] = @reminder.user_id || current_user&.id
          end
        else
          payload[:user_id] = @reminder.user_id || current_user&.id
        end

        if @reminder.update(payload)
          render json: reminder_json(@reminder), status: :ok
        else
          render json: { error: 'Failed to update reminder', errors: @reminder.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[RemindersController#update] #{e.class}: #{e.message}"
        render json: { error: 'Server error updating reminder', message: e.message }, status: :internal_server_error
      end

      def complete
        @reminder.update!(is_completed: true, completed_at: Time.current, user_id: (@reminder.user_id || current_user&.id))
        render json: reminder_json(@reminder), status: :ok
      rescue => e
        Rails.logger.error "[RemindersController#complete] #{e.class}: #{e.message}"
        render json: { error: 'Server error completing reminder', message: e.message }, status: :internal_server_error
      end

      def destroy
        @reminder.destroy!
        head :no_content
      rescue => e
        Rails.logger.error "[RemindersController#destroy] #{e.class}: #{e.message}"
        render json: { error: 'Server error deleting reminder', message: e.message }, status: :internal_server_error
      end

      private

      def set_company_scope
        unless current_user
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end
        
        company_id = current_company_id
        
        unless company_id.present?
          render json: { error: 'No company context' }, status: :forbidden
          return
        end
        
        @company = ::Company.find_by(id: company_id)
        
        if @company.nil?
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
      end

      def set_lead
        # STRICT TENANT ISOLATION: Only access leads in same company
        @lead = @company.leads.find_by(id: params[:lead_id])
        unless @lead
          render json: { error: 'Lead not found or access denied' }, status: :not_found
          return
        end
      end

      def set_reminder
        # STRICT TENANT ISOLATION: Only access reminders through lead scoped to company
        lead = @company.leads.find_by(id: params[:lead_id])
        unless lead
          render json: { error: 'Lead not found or access denied' }, status: :not_found
          return
        end
        
        @reminder = lead.reminders.find_by(id: params[:id])
        unless @reminder
          render json: { error: 'Reminder not found or access denied' }, status: :not_found
          return
        end
      end

      def extract_reminder_params
        raw = if params[:reminder].present?
                p = params[:reminder]
                p.respond_to?(:to_unsafe_h) ? p.to_unsafe_h : p
              else
                params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
              end

        is_completed_val = raw.key?('is_completed') ? raw['is_completed'] : 
                          raw.key?(:is_completed) ? raw[:is_completed] :
                          raw.key?('isCompleted') ? raw['isCompleted'] :
                          raw.key?(:isCompleted) ? raw[:isCompleted] : nil

        mapped = {
          reminder_type: raw['reminder_type'] || raw[:reminder_type] || raw['type'] || raw[:type],
          title:         raw['title'] || raw[:title],
          description:   raw['description'] || raw[:description],
          due_date:      parse_time(raw['due_date'] || raw[:due_date] || raw['dueDate'] || raw[:dueDate]),
          priority:      raw['priority'] || raw[:priority],
          is_completed:  is_completed_val,
        }.compact_blank

        mapped[:is_completed] = is_completed_val if is_completed_val == false

        ActionController::Parameters.new(mapped).permit!
      end

      def reminder_json(reminder)
        {
          id: reminder.id,
          leadId: reminder.lead_id,
          userId: reminder.user_id,
          type: reminder.reminder_type,
          title: reminder.title,
          description: reminder.description,
          dueDate: reminder.due_date&.iso8601,
          isCompleted: reminder.is_completed || false,
          priority: reminder.priority,
          createdAt: reminder.created_at&.iso8601,
          updatedAt: reminder.updated_at&.iso8601
        }.compact
      end

      def parse_time(value)
        return nil if value.blank?
        Time.zone.parse(value.to_s)
      rescue
        nil
      end
    end
  end
end

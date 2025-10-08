# frozen_string_literal: true
module Api
  module Crm
    class RemindersController < ApplicationController
      before_action :set_lead, only: [:index, :create, :update]
      before_action :set_reminder, only: [:update, :complete, :destroy]

      def index
        reminders = @lead.reminders.order(due_date: :asc)
        render json: reminders.map { |r| reminder_json(r) }, status: :ok
      end

      def create
        data = extract_reminder_params
        reminder = @lead.reminders.build(data)
        # match your create default
        reminder.user_id ||= 1
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
        # Never allow user_id to become NULL.
        raw = params[:reminder].respond_to?(:to_unsafe_h) ? params[:reminder].to_unsafe_h : (params[:reminder] || {})
        uid = raw['user_id'] || raw[:user_id]
        if uid && uid.to_s.strip != ''
          payload[:user_id] = (uid.to_s =~ /^\d+$/) ? uid.to_i : (@reminder.user_id || 1)
        else
          payload[:user_id] = @reminder.user_id || 1
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
        @reminder.update!(is_completed: true, completed_at: Time.current, user_id: (@reminder.user_id || 1))
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

      def set_lead
        @lead = Lead.find(params[:lead_id])
      end

      def set_reminder
        @reminder = Reminder.find(params[:id])
      end

      # No user_id here—never invent or null it out from params mapping.
      def extract_reminder_params
        raw = if params[:reminder].present?
                p = params[:reminder]
                p.respond_to?(:to_unsafe_h) ? p.to_unsafe_h : p
              else
                params.respond_to?(:to_unsafe_h) ? params.to_unsafe_h : params.to_h
              end

        mapped = {
          reminder_type: raw['reminder_type'] || raw[:reminder_type] || raw['type'] || raw[:type] || 'follow_up',
          title:         raw['title'] || raw[:title],
          description:   raw['description'] || raw[:description],
          due_date:      parse_time(raw['due_date'] || raw[:due_date] || raw['dueDate'] || raw[:dueDate]),
          priority:      raw['priority'] || raw[:priority] || 'medium',
          is_completed:  raw['is_completed'] || raw[:is_completed] || raw['isCompleted'] || raw[:isCompleted],
        }.compact

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

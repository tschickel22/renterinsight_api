# frozen_string_literal: true

module Api
  module Crm
    class RemindersController < ApplicationController
      before_action :set_lead, only: [:index, :create]
      before_action :set_reminder, only: [:complete, :destroy]

      def index
        reminders = @lead.reminders.order(due_date: :asc)
        render json: reminders.map { |r| reminder_json(r) }
      end

      def create
        reminder = @lead.reminders.build(reminder_params)
        # Keep your existing default; accept FE placeholder gracefully
        reminder.user_id = normalize_user_id(params.dig(:reminder, :user_id)) || current_user&.id || 1

        if reminder.save
          render json: reminder_json(reminder), status: :created
        else
          render json: { errors: reminder.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def complete
        @reminder.update!(is_completed: true, completed_at: Time.current)
        render json: reminder_json(@reminder)
      end

      def destroy
        @reminder.destroy!
        head :no_content
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id] || params[:id])
      end

      def set_reminder
        @reminder = Reminder.find(params[:id])
      end

      # ---- Key change: accept both :type and :reminder_type from FE ----
      # Also accept camelCase aliases safely, parse due_date, and keep your
      # JSON/DB shape (reminder_type column).
      def reminder_params
        raw = params.require(:reminder).permit(
          :type, :reminder_type, :title, :description, :due_date, :priority, :user_id,
          :lead_id, :is_completed, :completed_at,
          # camelCase fallbacks if FE ever sends them
          :reminderType, :dueDate, :isCompleted
        )

        # prefer explicit reminder_type, then type, then camelCase
        rtype = raw[:reminder_type].presence || raw[:type].presence || raw[:reminderType].presence

        parsed_due =
          if raw[:due_date].present?
            safe_parse_time(raw[:due_date])
          elsif raw[:dueDate].present?
            safe_parse_time(raw[:dueDate])
          else
            nil
          end

        {
          reminder_type: rtype,                                             # <— NOT NULL on DB
          title:         raw[:title],
          description:   raw[:description],
          due_date:      parsed_due || (Time.current + 1.day),
          priority:      raw[:priority].presence || 'medium',
          is_completed:  truthy?(raw[:is_completed]) || truthy?(raw[:isCompleted])
        }.compact
      end

      def reminder_json(reminder)
        {
          id:          reminder.id,
          leadId:      reminder.lead_id,
          userId:      reminder.user_id,
          type:        reminder.reminder_type,
          title:       reminder.title,
          description: reminder.description,
          dueDate:     reminder.due_date,
          isCompleted: reminder.is_completed,
          priority:    reminder.priority,
          createdAt:   reminder.created_at,
          updatedAt:   reminder.updated_at
        }.compact
      end

      def safe_parse_time(v)
        Time.zone.parse(v.to_s)
      rescue
        nil
      end

      def truthy?(v)
        ActiveModel::Type::Boolean.new.cast(v)
      end

      def normalize_user_id(v)
        s = v.to_s
        return nil if s.blank? || s == 'current-user'
        s =~ /^\d+$/ ? s.to_i : nil
      end
    end
  end
end

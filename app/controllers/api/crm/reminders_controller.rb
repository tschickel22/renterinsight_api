# frozen_string_literal: true
module Api
  module Crm
    class RemindersController < ApplicationController
      before_action :set_lead, only: [:index, :create]
      before_action :set_reminder, only: [:complete, :destroy]

      # GET /api/crm/leads/:lead_id/reminders
      def index
        reminders = @lead.reminders.order(due_date: :asc)
        render json: reminders.map { |r| reminder_json(r) }, status: :ok
      end

      # POST /api/crm/leads/:lead_id/reminders
      # Accepts flexible shapes: type/reminder_type, due_date/dueDate, etc.
      def create
        raw = params[:reminder].presence || params.permit!.to_h
        permitted = ActionController::Parameters.new(raw).permit(
          :type, :reminder_type, :title, :description, :due_date, :dueDate, :priority, :user_id,
          :lead_id, :is_completed, :isCompleted, :completed_at
        )

        rtype = permitted[:reminder_type].presence || permitted[:type].presence
        due =
          parse_time(permitted[:due_date]) ||
          parse_time(permitted[:dueDate])

        reminder = @lead.reminders.build(
          reminder_type: rtype,
          title:         permitted[:title],
          description:   permitted[:description],
          due_date:      due || (Time.current + 1.day),
          priority:      (permitted[:priority].presence || 'medium'),
          is_completed:  truthy?(permitted[:is_completed]) || truthy?(permitted[:isCompleted]),
          user_id:       normalize_user_id(permitted[:user_id]) || current_user&.id || 1
        )

        if reminder.save
          render json: reminder_json(reminder), status: :created
        else
          render json: { errors: reminder.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/crm/reminders/:id/complete
      def complete
        @reminder.update!(is_completed: true, completed_at: Time.current)
        render json: reminder_json(@reminder), status: :ok
      end

      # DELETE /api/crm/leads/:lead_id/reminders/:id
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
        }
      end

      def parse_time(v)
        Time.zone.parse(v.to_s) if v.present?
      rescue
        nil
      end

      def truthy?(v)
        ActiveModel::Type::Boolean.new.cast(v)
      end

      def normalize_user_id(v)
        s = v.to_s
        return nil if s.blank? || s == 'current-user'
        (s =~ /^\d+$/) ? s.to_i : nil
      end
    end
  end
end

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
        reminder.user_id = current_user&.id || 1 # Fallback for testing
        
        if reminder.save
          render json: reminder_json(reminder), status: :created
        else
          render json: { errors: reminder.errors.full_messages }, status: :unprocessable_entity
        end
      end

      def complete
        @reminder.complete!
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

      def reminder_params
        p = params.require(:reminder).permit(
          :type, :title, :description, :due_date, :priority, :user_id
        )
        
        {
          reminder_type: p[:type],
          title: p[:title],
          description: p[:description],
          due_date: p[:due_date],
          priority: p[:priority] || 'medium'
        }.compact
      end

      def reminder_json(reminder)
        {
          id: reminder.id,
          leadId: reminder.lead_id,
          userId: reminder.user_id,
          type: reminder.reminder_type,
          title: reminder.title,
          description: reminder.description,
          dueDate: reminder.due_date,
          isCompleted: reminder.is_completed,
          priority: reminder.priority,
          createdAt: reminder.created_at,
          updatedAt: reminder.updated_at
        }.compact
      end
    end
  end
end

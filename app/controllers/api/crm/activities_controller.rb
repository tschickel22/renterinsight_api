module Api
  module Crm
    class ActivitiesController < ApplicationController
      before_action :set_lead, only: [:index, :create]

      def index
        activities = @lead.activities.includes(:user).order(created_at: :desc)
        render json: activities.map { |a| activity_json(a) }
      end

      def create
        activity = @lead.activities.build(activity_params)
        activity.user_id = current_user&.id || 1 # Fallback to id 1 for testing
        
        if activity.save
          render json: activity_json(activity), status: :created
        else
          render json: { errors: activity.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id] || params[:id])
      end

      def activity_params
        p = params.require(:activity).permit(
          :type, :description, :outcome, :duration, 
          :scheduled_date, :completed_date, :user_id, metadata: {}
        )
        
        {
          activity_type: p[:type],
          description: p[:description],
          outcome: p[:outcome],
          duration: p[:duration],
          scheduled_date: p[:scheduled_date],
          completed_date: p[:completed_date],
          metadata: p[:metadata] || {}
        }.compact
      end

      def activity_json(activity)
        {
          id: activity.id,
          leadId: activity.lead_id,
          type: activity.activity_type,
          description: activity.description,
          outcome: activity.outcome,
          duration: activity.duration,
          scheduledDate: activity.scheduled_date,
          completedDate: activity.completed_date,
          userId: activity.user_id,
          metadata: activity.metadata,
          createdAt: activity.created_at,
          updatedAt: activity.updated_at
        }.compact
      end
    end
  end
end

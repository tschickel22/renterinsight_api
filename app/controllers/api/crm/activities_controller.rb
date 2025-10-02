module Api
  module Crm
    class ActivitiesController < ApplicationController
      skip_before_action :verify_authenticity_token, raise: false

      # GET /api/crm/leads/:lead_id/activities
      def index
        activities = @lead.activities.includes(:user).order(created_at: :desc)
        render json: activities.map { |a| activity_json(a) }
      end

      # POST /api/crm/leads/:lead_id/activities
      def create
        activity = @lead.activities.build(activity_params)
        activity.user_id ||= (current_user&.id || 1)

        if activity.save
          render json: activity_json(activity), status: :created
        else
          render json: { errors: activity.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id] || params[:id] || params[:leadId])
      end

      # Accept nested/root; camel/snake; avoid STI "type" pitfalls.
      def activity_params
        base = params[:activity].is_a?(ActionController::Parameters) ? params.require(:activity) : params
        p = base.permit(
          :activity_type, :activityType, :type,
          :description, :outcome, :duration,
          :scheduled_date, :scheduledDate,
          :completed_date, :completedDate,
          :user_id, :userId, :lead_id, :leadId,
          metadata: {}
        )
        atype = p[:activity_type] || p[:activityType] || p[:type]

        {
          activity_type: atype,
          description:   p[:description],
          outcome:       p[:outcome],
          duration:      p[:duration],
          scheduled_date: p[:scheduled_date] || p[:scheduledDate],
          completed_date: p[:completed_date] || p[:completedDate],
          user_id:       p[:user_id] || p[:userId],
          metadata:      p[:metadata] || {}
        }.compact
      end

      def activity_json(activity)
        {
          id:            activity.id,
          leadId:        activity.lead_id,
          type:          activity.activity_type,
          description:   activity.description,
          outcome:       activity.outcome,
          duration:      activity.duration,
          scheduledDate: activity.scheduled_date,
          completedDate: activity.completed_date,
          userId:        activity.user_id,
          metadata:      activity.metadata,
          createdAt:     activity.created_at,
          updatedAt:     activity.updated_at
        }.compact
      end
    end
  end
end

module Api
  module Crm
    class ActivitiesController < ApplicationController
      before_action :set_lead, only: [:index, :create]

      # GET /api/crm/leads/:lead_id/activities
      def index
        activities = @lead.activities.includes(:user).order(created_at: :desc)
        render json: activities.map { |a| activity_json(a) }
      end

      # POST /api/crm/leads/:lead_id/activities
      def create
        activity = @lead.activities.build(activity_params)
        activity.user_id ||= (current_user&.id || 1) # fallback user for dev/test

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

      # Accept nested or root payload; tolerate camelCase/snake_case; avoid STI gotchas around "type".
      def activity_params
        # Support both { activity: {...} } and root-level JSON
        base = params[:activity].is_a?(ActionController::Parameters) ? params.require(:activity) : params

        p = base.permit(
          :activity_type, :activityType, :type, # various ways FE may send the type
          :description, :outcome, :duration,
          :scheduled_date, :scheduledDate,
          :completed_date, :completedDate,
          :user_id, :userId, :lead_id, :leadId,
          metadata: {}
        )

        # Prefer explicit keys; fall back to :type last (classic STI column name, but we're mapping it)
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

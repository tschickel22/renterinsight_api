module Api
  module Crm
    class ActivitiesController < ApplicationController
      # Allow JSON POSTs without CSRF token
      skip_before_action :verify_authenticity_token, raise: false
      before_action :set_lead

      # GET /api/crm/leads/:lead_id/activities
      def index
        activities = @lead.activities.order(created_at: :desc)
        render json: activities.map { |a| activity_json(a) }
      end

      # POST /api/crm/leads/:lead_id/activities
      def create
        attrs = activity_params
        activity = @lead.activities.build(attrs)

        # Only set a user if you actually have one
        if respond_to?(:current_user) && current_user&.id.present?
          activity.user_id = current_user.id
        end

        activity.save!
        render json: activity_json(activity), status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { errors: e.record.errors.full_messages }, status: :unprocessable_entity
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id] || params[:id] || params[:leadId])
      end

      # Tolerant strong params: nested or root, camelCase or snake_case, multiple aliases
      def activity_params
        permitted_nested = params[:activity].is_a?(ActionController::Parameters) ?
          params.require(:activity).permit(
            :type, :activityType, :activity_type, :kind,
            :description, :outcome, :duration,
            :scheduled_date, :scheduledDate,
            :completed_date, :completedDate,
            :user_id, :userId, :leadId,
            metadata: {}
          ) : {}

        permitted_root = params.permit(
          :type, :activityType, :activity_type, :kind,
          :description, :outcome, :duration,
          :scheduled_date, :scheduledDate,
          :completed_date, :completedDate,
          :user_id, :userId, :leadId,
          metadata: {}
        )

        raw = permitted_nested.to_h.merge(permitted_root.to_h)

        activity_type =
          raw['type'] ||
          raw['activityType'] ||
          raw['activity_type'] ||
          raw['kind']

        {
          activity_type:  activity_type,
          description:    raw['description'],
          outcome:        raw['outcome'],
          duration:       raw['duration'],
          scheduled_date: raw['scheduled_date'] || raw['scheduledDate'],
          completed_date: raw['completed_date'] || raw['completedDate'],
          metadata:       raw['metadata'] || {}
        }.compact
      end

      def activity_json(activity)
        {
          id:             activity.id,
          leadId:         activity.lead_id,
          type:           activity.activity_type,
          description:    activity.description,
          outcome:        activity.outcome,
          duration:       activity.duration,
          scheduledDate:  activity.scheduled_date,
          completedDate:  activity.completed_date,
          userId:         activity.user_id,
          metadata:       activity.metadata,
          createdAt:      activity.created_at,
          updatedAt:      activity.updated_at
        }.compact
      end
    end
  end
end

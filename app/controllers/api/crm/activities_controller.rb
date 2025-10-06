# frozen_string_literal: true
module Api
  module Crm
    class ActivitiesController < ApplicationController
      before_action :set_lead

      # GET /api/crm/leads/:lead_id/activities
      def index
        activities = @lead.activities.order(created_at: :desc)
        render json: activities.map { |a| activity_json(a) }, status: :ok
      end

      # POST /api/crm/leads/:lead_id/activities
      def create
        attrs = normalize_activity_params
        activity = @lead.activities.new(attrs)
        activity.user_id ||= (current_user&.id || 1)

        if activity.save
          render json: activity_json(activity), status: :created
        else
          render json: { errors: activity.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id])
      end

      def normalize_activity_params
        raw = if params[:activity].present?
          params.require(:activity).permit(
            :activity_type, :type, :description, :outcome, :duration,
            :scheduled_date, :completed_date, :user_id, metadata: {}
          ).to_h
        else
          params.permit(
            :activity_type, :type, :description, :outcome, :duration,
            :scheduled_date, :completed_date, :user_id, metadata: {}
          ).to_h
        end

        atype = raw[:activity_type].presence || raw[:type].presence

        {
          activity_type: atype,
          description: raw[:description],
          outcome: raw[:outcome],
          duration: raw[:duration],
          scheduled_date: raw[:scheduled_date],
          completed_date: raw[:completed_date],
          user_id: raw[:user_id],
          metadata: (raw[:metadata].presence || {})
        }.compact
      end

      def activity_json(activity)
        {
          id: activity.id,
          leadId: activity.lead_id,
          userId: activity.user_id,
          type: activity.activity_type,
          description: activity.description,
          outcome: activity.outcome,
          duration: activity.duration,
          scheduledDate: activity.scheduled_date&.iso8601,
          completedDate: activity.completed_date&.iso8601,
          metadata: activity.metadata || {},
          createdAt: activity.created_at&.iso8601,
          updatedAt: activity.updated_at&.iso8601
        }.compact
      end
    end
  end
end

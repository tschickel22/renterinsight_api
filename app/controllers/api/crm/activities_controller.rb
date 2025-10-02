# app/controllers/api/crm/activities_controller.rb
module Api
  module Crm
    class ActivitiesController < ApplicationController
      skip_before_action :verify_authenticity_token, raise: false
      before_action :set_lead

      # GET /api/crm/leads/:lead_id/activities
      def index
        activities = @lead.activities.order(created_at: :desc)
        render json: activities.map { |a| activity_json(a) }
      end

      # POST /api/crm/leads/:lead_id/activities
      #
      # Accepts either:
      #   { "activity": { "type": "call", "description": "Intro call" } }
      # or
      #   { "type": "call", "description": "Intro call" }
      def create
        attrs = activity_params_from(params)
        activity = @lead.activities.build(attrs)

        # Only set user_id if a users table exists AND a value was provided
        if ActiveRecord::Base.connection.data_source_exists?('users')
          uid = params.dig(:activity, :user_id) ||
                params.dig(:activity, :userId) ||
                params[:user_id] ||
                params[:userId]
          activity.user_id = uid if uid.present?
        end

        if activity.save
          render json: activity_json(activity), status: :created
        else
          render json: { errors: activity.errors.full_messages }, status: :unprocessable_entity
        end
      rescue ActionController::ParameterMissing => e
        render json: { errors: [e.message] }, status: :unprocessable_entity
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id] || params[:id])
      end

      # Build attributes for Activity from either nested or root params.
      def activity_params_from(p)
        raw =
          if p[:activity].is_a?(ActionController::Parameters)
            p.require(:activity)
          else
            p
          end

        permitted = raw.permit(
          :type, :description, :outcome, :duration,
          :scheduled_date, :completed_date,
          :user_id, :userId, :leadId,
          metadata: {}
        )

        {
          activity_type: permitted[:type] || p[:type],
          description: permitted[:description],
          outcome: permitted[:outcome],
          duration: permitted[:duration],
          scheduled_date: permitted[:scheduled_date],
          completed_date: permitted[:completed_date],
          metadata: permitted[:metadata] || {}
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

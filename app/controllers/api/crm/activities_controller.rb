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
      #   { "activity": { "type": "call", "description": "..." } }
      # or
      #   { "type": "call", "description": "..." }
      def create
        attrs = build_attrs_from_params

        if attrs[:activity_type].blank?
          return render json: { errors: ["Activity type can't be blank"] }, status: :unprocessable_entity
        end

        activity = @lead.activities.build(attrs)

        # Only set user_id if a users table exists AND something was provided
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

      # Pull attributes robustly from nested or root payloads.
      def build_attrs_from_params
        # Prefer the nested object if present; otherwise use root.
        raw =
          if params[:activity].is_a?(ActionController::Parameters)
            params.require(:activity)
          else
            params
          end

        permitted = raw.permit(
          :type, :description, :outcome, :duration,
          :scheduled_date, :completed_date,
          :user_id, :userId, :leadId,
          metadata: {}
        )

        # Be defensive about how we read "type"
        # (supports symbol/string keys and nested/root forms)
        extracted_type =
          params.dig(:activity, :type) ||
          params.dig('activity', 'type') ||
          permitted[:type] ||
          params[:type] ||
          params['type']

        {
          activity_type: extracted_type,
          description:   permitted[:description] || params[:description],
          outcome:       permitted[:outcome]     || params[:outcome],
          duration:      permitted[:duration]    || params[:duration],
          scheduled_date: permitted[:scheduled_date] || params[:scheduled_date],
          completed_date: permitted[:completed_date] || params[:completed_date],
          metadata:      permitted[:metadata] || {}
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

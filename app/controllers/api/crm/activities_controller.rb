module Api
  module Crm
    class ActivitiesController < ApplicationController
      # This is an API endpoint; don’t enforce CSRF tokens
      skip_before_action :verify_authenticity_token, raise: false
      before_action :set_lead

      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: 'not_found' }, status: :not_found
      end

      rescue_from ActionController::ParameterMissing do |e|
        render json: { error: 'bad_request', message: e.message }, status: :unprocessable_entity
      end

      # GET /api/crm/leads/:lead_id/activities
      def index
        activities = @lead.activities.order(created_at: :desc)
        render json: activities.map { |a| activity_json(a) }
      end

      # POST /api/crm/leads/:lead_id/activities
      # Accepts either:
      #   { "activity": { "type":"call", "description":"..." } }
      # or
      #   { "type":"call", "description":"..." }
      def create
        p = extract_payload

        attrs = {
          activity_type:  p[:type],
          description:    p[:description],
          outcome:        p[:outcome],
          duration:       p[:duration],
          scheduled_date: p[:scheduled_date],
          completed_date: p[:completed_date],
          metadata:       p[:metadata] || {}
        }.compact

        activity = @lead.activities.new(attrs)
        activity.user_id = (params[:user_id] || params[:userId]).presence || 1

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

      # Strong params that tolerate nested or root payloads (no 500s)
      def extract_payload
        if params[:activity].present?
          params.require(:activity).permit(
            :type, :description, :outcome, :duration,
            :scheduled_date, :completed_date, metadata: {}
          )
        else
          params.permit(
            :type, :description, :outcome, :duration,
            :scheduled_date, :completed_date, metadata: {}
          )
        end
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

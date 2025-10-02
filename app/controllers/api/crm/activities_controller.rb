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
      # Accepts either:
      #   { "activity": { "type": "call", "description": "..." } }
      # or
      #   { "type": "call", "description": "..." }
      def create
        attrs = build_attrs_from_params

        # DEBUG: log what we're seeing to help diagnose
        Rails.logger.info("[Activities#create] raw_params=#{params.to_unsafe_h}")
        Rails.logger.info("[Activities#create] extracted_attrs=#{attrs.inspect}")

        if attrs[:activity_type].blank?
          return render json: { errors: ["Activity type can't be blank"] }, status: :unprocessable_entity
        end

        activity = @lead.activities.build(attrs)

        # Only set user_id if a users table exists AND a value was provided
        if ActiveRecord::Base.connection.data_source_exists?('users')
          uid = fetch_first_present(
            params.dig(:activity, :user_id),
            params.dig(:activity, :userId),
            params[:user_id],
            params[:userId]
          )
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

      # Pull attributes robustly from nested or root payloads
      # and tolerate different key spellings.
      def build_attrs_from_params
        nested = params[:activity].is_a?(ActionController::Parameters) ? params.require(:activity) : nil
        root   = params

        # Permit common fields on whichever layer is present
        permitted_nested = nested&.permit(
          :type, :activity_type, :kind, :description, :outcome, :duration,
          :scheduled_date, :completed_date, :user_id, :userId, :leadId,
          metadata: {}
        )
        permitted_root = root.permit(
          :type, :activity_type, :kind, :description, :outcome, :duration,
          :scheduled_date, :completed_date, :user_id, :userId, :leadId,
          metadata: {}
        )

        extracted_type = normalize_type(
          fetch_first_present(
            # nested keys (preferred)
            permitted_nested&.[](:type),
            permitted_nested&.[](:activity_type),
            permitted_nested&.[](:kind),

            # raw nested (string keys just in case)
            nested&.[]('type'),
            nested&.[]('activity_type'),
            nested&.[]('kind'),

            # root keys
            permitted_root[:type],
            permitted_root[:activity_type],
            permitted_root[:kind],
            root[:type],
            root[:activity_type],
            root[:kind]
          )
        )

        {
          activity_type: extracted_type,
          description:   fetch_first_present(permitted_nested&.[](:description), permitted_root[:description], root[:description]),
          outcome:       fetch_first_present(permitted_nested&.[](:outcome), permitted_root[:outcome], root[:outcome]),
          duration:      fetch_first_present(permitted_nested&.[](:duration), permitted_root[:duration], root[:duration]),
          scheduled_date: fetch_first_present(permitted_nested&.[](:scheduled_date), permitted_root[:scheduled_date], root[:scheduled_date]),
          completed_date: fetch_first_present(permitted_nested&.[](:completed_date), permitted_root[:completed_date], root[:completed_date]),
          metadata:      fetch_first_present(permitted_nested&.[](:metadata), permitted_root[:metadata]) || {}
        }.compact
      end

      # Helper: first non-nil / non-empty value
      def fetch_first_present(*vals)
        vals.find { |v| v.present? }
      end

      # Normalize type to a lowercase string (model can do inclusion)
      def normalize_type(val)
        return nil if val.nil?
        val.is_a?(String) ? val.strip.downcase : val.to_s.downcase
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

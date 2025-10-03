# frozen_string_literal: true
module Api
  module Crm
    class ActivitiesController < ApplicationController
      skip_before_action :verify_authenticity_token, raise: false
      before_action :set_lead

      # GET /api/crm/leads/:lead_id/activities
      def index
        activities = Activity.where(lead_id: @lead.id).order(created_at: :desc)
        render json: activities.map { |a| activity_json(a) }
      end

      # POST /api/crm/leads/:lead_id/activities
      # Accepts either:
      #   { "activity": { "type": "call", "description": "..." } }
      #   { "type": "call", "description": "..." }
      def create
        payload =
          if params[:activity].present?
            params[:activity]
          else
            # Build a safe root-level params object so root payloads work
            ActionController::Parameters.new(
              type:            params[:type],
              description:     params[:description],
              outcome:         params[:outcome],
              duration:        params[:duration],
              scheduled_date:  params[:scheduled_date],
              completed_date:  params[:completed_date],
              metadata:        params[:metadata]
            )
          end

        attrs = extract_attrs(payload)

        Rails.logger.info("[Activities#create] parsed=#{attrs.inspect}")

        if attrs[:activity_type].blank?
          return render json: { errors: ["Activity type can't be blank"] }, status: :unprocessable_entity
        end

        # Build without relying on lead.activities association
        # and without setting user_id (avoids users FK requirement)
        activity = Activity.new({ lead_id: @lead.id }.merge(attrs))

        if activity.save
          render json: activity_json(activity), status: :created
        else
          render json: { errors: activity.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id] || params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { errors: ["Lead not found"] }, status: :not_found
      end

      # Pulls values from either snake_case or camelCase keys
      def extract_attrs(h)
        raw = h.respond_to?(:to_unsafe_h) ? h.to_unsafe_h : h

        atype = raw['type'] || raw[:type] ||
                raw['activity_type'] || raw[:activity_type] ||
                raw['activityType'] || raw[:activityType] ||
                raw['kind'] || raw[:kind]

        {
          activity_type:  normalize(atype),
          description:    fetch_any(raw, :description, :Description),
          outcome:        fetch_any(raw, :outcome, :Outcome),
          duration:       fetch_any(raw, :duration, :Duration),
          scheduled_date: fetch_any(raw, :scheduled_date, :scheduledDate),
          completed_date: fetch_any(raw, :completed_date, :completedDate),
          metadata:       raw['metadata'].is_a?(Hash) ? raw['metadata'] : {}
          # intentionally not setting :user_id
        }.compact
      end

      def fetch_any(hash, *keys)
        keys = keys.flat_map { |k| [k, k.to_s, k.to_s.camelize(:lower)] }
        keys.each { |k| return hash[k] if hash.key?(k) }
        nil
      end

      def normalize(v)
        v.is_a?(String) ? v.strip.downcase : v
      end

      def activity_json(a)
        {
          id:            a.id,
          leadId:        a.lead_id,
          type:          a.activity_type,
          description:   a.description,
          outcome:       a.outcome,
          duration:      a.duration,
          scheduledDate: a.scheduled_date,
          completedDate: a.completed_date,
          userId:        a.user_id,
          metadata:      a.metadata,
          createdAt:     a.created_at,
          updatedAt:     a.updated_at
        }.compact
      end
    end
  end
end

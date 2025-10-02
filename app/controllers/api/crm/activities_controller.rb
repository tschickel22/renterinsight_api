# app/controllers/api/crm/activities_controller.rb
# frozen_string_literal: true
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
        payload = params[:activity].presence || params

        atype = first_present(
          payload[:type],
          payload[:activity_type],
          payload[:kind],
          dig_camel(payload, :type),
          dig_camel(payload, :activity_type),
          dig_camel(payload, :kind)
        )

        attrs = {
          activity_type: normalize_type(atype),
          description:   first_present(payload[:description], dig_camel(payload, :description)),
          outcome:       first_present(payload[:outcome],     dig_camel(payload, :outcome)),
          duration:      first_present(payload[:duration],    dig_camel(payload, :duration)),
          scheduled_date:first_present(payload[:scheduled_date], dig_camel(payload, :scheduled_date)),
          completed_date:first_present(payload[:completed_date], dig_camel(payload, :completed_date)),
          metadata:      payload[:metadata].is_a?(Hash) ? payload[:metadata] : {}
        }.compact

        if attrs[:activity_type].blank?
          return render json: { errors: ["Activity type can't be blank"] }, status: :unprocessable_entity
        end

        activity = @lead.activities.build(attrs)

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

      def first_present(*vals)
        vals.find { |v| v.present? }
      end

      def dig_camel(h, key)
        # Allow camelCase like scheduledDate, completedDate, activityType
        return nil unless h.respond_to?(:to_unsafe_h) || h.is_a?(Hash)
        hash = h.respond_to?(:to_unsafe_h) ? h.to_unsafe_h : h
        hash[key.to_s.camelize(:lower)]
      end

      def normalize_type(val)
        return nil if val.blank?
        val.to_s.strip.downcase
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

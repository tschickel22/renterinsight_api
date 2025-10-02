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
      #   { "type": "call", "description": "..." }
      def create
        payload = params[:activity].presence || params

        attrs = extract_attrs(payload)
        Rails.logger.info("[Activities#create] parsed=#{attrs.inspect}")

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

      def extract_attrs(h)
        # allow ActionController::Parameters or Hash
        raw = h.respond_to?(:to_unsafe_h) ? h.to_unsafe_h : h

        # fetch with both snake & camel keys
        atype = raw['type'] || raw[:type] || raw['activity_type'] || raw[:activity_type] ||
                raw['kind'] || raw[:kind] || raw['activityType'] || raw['scheduledType']

        {
          activity_type: normalize(atype),
          description:   pick(raw, :description),
          outcome:       pick(raw, :outcome),
          duration:      pick(raw, :duration),
          scheduled_date: pick(raw, :scheduled_date, :scheduledDate),
          completed_date: pick(raw, :completed_date, :completedDate),
          metadata:      raw['metadata'].is_a?(Hash) ? raw['metadata'] : {}
          # user_id intentionally omitted so no FK needed
        }.compact
      end

      def pick(hash, *keys)
        keys = [keys, keys.map { |k| k.to_s }, keys.map { |k| k.to_s.camelize(:lower) }].flatten
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

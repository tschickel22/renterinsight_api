# frozen_string_literal: true
module Api
  module Crm
    class ActivitiesController < ApplicationController
      before_action :set_lead

      # GET /api/crm/leads/:lead_id/activities
      def index
        activities = @lead.activities.order(created_at: :desc)
        render json: activities, each_serializer: ActivitySerializer
      end

      # POST /api/crm/leads/:lead_id/activities
      # Accepts flexible input; maps camelCase/snake_case and common aliases
      # to your DB columns without changing response shape.
      def create
        attrs = normalize_activity_params
        @activity = @lead.activities.new(attrs)

        # Default user if FE sends placeholder
        if @activity.user_id.blank? || @activity.user_id.to_s == 'current-user'
          @activity.user_id = current_user&.id || 1
        end

        if @activity.save
          render json: @activity, serializer: ActivitySerializer, status: :created
        else
          render json: { errors: @activity.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id])
      end

      # Keep your strong params but allow typical FE variations.
      def activity_params
        params.require(:activity).permit(
          :activity_type, :type, :title, :subject,
          :description, :notes, :outcome,
          :duration,
          :scheduled_date, :scheduledDate,
          :performed_at, :performedAt,
          :occurred_at, :occurredAt,
          :due_date, :dueDate,
          :priority,
          :user_id,
          metadata: {}
        )
      end

      # Map flexible input to the exact DB columns your model expects.
      def normalize_activity_params
        p = activity_params

        # Activity type: prefer activity_type, then type (string), then subject/title as fallback
        atype =
          p[:activity_type].presence ||
          p[:type].presence ||
          nil

        # When FE sends separate subject/title/notes, keep description primary
        desc =
          p[:description].presence ||
          p[:notes].presence

        # Choose a single timestamp field (keep your column names):
        occurred =
          parse_time(p[:performed_at]) ||
          parse_time(p[:performedAt]) ||
          parse_time(p[:occurred_at]) ||
          parse_time(p[:occurredAt])

        scheduled =
          parse_time(p[:scheduled_date]) ||
          parse_time(p[:scheduledDate]) ||
          parse_time(p[:due_date]) ||
          parse_time(p[:dueDate])

        {
          activity_type: atype,
          description:   desc,
          outcome:       p[:outcome],
          duration:      p[:duration],
          scheduled_date: scheduled,     # keep your column
          occurred_at:    occurred,      # if your model has it; harmless if ignored by strong-attrs
          user_id:       normalize_user_id(p[:user_id]),
          metadata:      p[:metadata].presence || {}
        }.compact
      end

      def parse_time(v)
        Time.zone.parse(v.to_s) if v.present?
      rescue
        nil
      end

      def normalize_user_id(v)
        s = v.to_s
        return nil if s.blank? || s == 'current-user'
        s =~ /^\d+$/ ? s.to_i : nil
      end
    end
  end
end

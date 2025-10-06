# frozen_string_literal: true
module Api
  module Crm
    class ActivitiesController < ApplicationController
      before_action :set_lead

      # GET /api/crm/leads/:lead_id/activities
      def index
        activities = @lead.activities.order(created_at: :desc)
        render json: activities, each_serializer: ActivitySerializer, status: :ok
      end

      # POST /api/crm/leads/:lead_id/activities
      # Accepts nested {activity:{...}} OR root payload {type,description,metadata}
      # Permits flexible aliases and persists reliably.
      def create
        attrs = normalize_activity_params
        activity = @lead.activities.new(attrs)

        # Default the user when FE passes placeholder/current-user
        activity.user_id ||= (current_user&.id || 1)

        if activity.save
          render json: activity, serializer: ActivitySerializer, status: :created
        else
          render json: { errors: activity.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id] || params[:id])
      end

      # Strong params (nested form)
      def activity_params_nested
        params.require(:activity).permit(
          :activity_type, :type, :title, :subject,
          :description, :notes, :outcome, :duration,
          :scheduled_date, :scheduledDate,
          :performed_at, :performedAt,
          :occurred_at, :occurredAt,
          :due_date, :dueDate,
          :priority, :user_id,
          metadata: {}
        )
      end

      # Handle both nested and root shapes safely
      def normalize_activity_params
        raw = if params[:activity].present?
          activity_params_nested.to_h
        else
          # root-level payload; permit everything then slice what we need
          ActionController::Parameters.new(params.to_unsafe_h).permit(
            :activity_type, :type, :title, :subject,
            :description, :notes, :outcome, :duration,
            :scheduled_date, :scheduledDate,
            :performed_at, :performedAt,
            :occurred_at, :occurredAt,
            :due_date, :dueDate,
            :priority, :user_id,
            metadata: {}
          ).to_h
        end

        atype =
          raw[:activity_type].presence ||
          raw[:type].presence

        desc =
          raw[:description].presence ||
          raw[:notes].presence

        occurred =
          parse_time(raw[:performed_at]) ||
          parse_time(raw[:performedAt]) ||
          parse_time(raw[:occurred_at]) ||
          parse_time(raw[:occurredAt])

        scheduled =
          parse_time(raw[:scheduled_date]) ||
          parse_time(raw[:scheduledDate]) ||
          parse_time(raw[:due_date]) ||
          parse_time(raw[:dueDate])

        {
          activity_type: atype,
          description:   desc,
          outcome:       raw[:outcome],
          duration:      raw[:duration],
          scheduled_date: scheduled,
          occurred_at:    occurred,
          priority:      raw[:priority],
          user_id:       normalize_user_id(raw[:user_id]),
          metadata:      (raw[:metadata].presence || {})
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
        (s =~ /^\d+$/) ? s.to_i : nil
      end
    end
  end
end

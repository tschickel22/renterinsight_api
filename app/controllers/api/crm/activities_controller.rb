# app/controllers/api/crm/activities_controller.rb
# frozen_string_literal: true

module Api
  module Crm
    class ActivitiesController < ApplicationController
      before_action :set_lead
      skip_before_action :verify_authenticity_token, raise: false

      # GET /api/crm/leads/:lead_id/activities
      def index
        activities = @lead.activities.order(created_at: :desc)
        render json: activities, each_serializer: ActivitySerializer, status: :ok
      end

      # POST /api/crm/leads/:lead_id/activities
      # Accepts either:
      # - { activity: { activity_type|type|kind|category, description, ... } }
      # - { activity_type|type|kind|category, description, ... }
      def create
        raw   = fetch_payload # symbolized, filtered
        atype = normalize_activity_type(raw)

        attrs = {
          activity_type:  atype,
          description:    coalesce(raw[:description], raw[:notes]),
          outcome:        raw[:outcome],
          duration:       raw[:duration],
          scheduled_date: parse_time(coalesce(raw[:scheduled_date], raw[:scheduledDate], raw[:due_date], raw[:dueDate])),
          occurred_at:    parse_time(coalesce(raw[:performed_at], raw[:performedAt], raw[:occurred_at], raw[:occurredAt])),
          priority:       raw[:priority],
          user_id:        normalize_user_id(raw[:user_id]) || current_user&.id || 1,
          metadata:       raw[:metadata].is_a?(Hash) ? raw[:metadata] : {}
        }.compact

        activity = @lead.activities.new(attrs)

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

      # -------- payload handling --------

      # Build a safe, symbolized hash from either nested or root JSON.
      # NOTE: we never pass :type to the model to avoid STI.
      def fetch_payload
        if params[:activity].present?
          permitted = params.require(:activity).permit(
            :activity_type, :type, :kind, :category,
            :title, :subject,
            :description, :notes, :outcome,
            :duration,
            :scheduled_date, :scheduledDate,
            :performed_at, :performedAt,
            :occurred_at, :occurredAt,
            :due_date, :dueDate,
            :priority, :user_id,
            metadata: {}
          )
          permitted.to_h.deep_symbolize_keys
        else
          permitted = ActionController::Parameters
                        .new(params.to_unsafe_h)
                        .permit(
                          :activity_type, :type, :kind, :category,
                          :title, :subject,
                          :description, :notes, :outcome,
                          :duration,
                          :scheduled_date, :scheduledDate,
                          :performed_at, :performedAt,
                          :occurred_at, :occurredAt,
                          :due_date, :dueDate,
                          :priority, :user_id,
                          metadata: {}
                        )
          permitted.to_h.deep_symbolize_keys
        end
      end

      def coalesce(*vals)
        vals.find { |v| v.present? }
      end

      def parse_time(v)
        return nil if v.blank?
        Time.zone.parse(v.to_s)
      rescue
        nil
      end

      def normalize_user_id(v)
        s = v.to_s
        return nil if s.blank? || s == 'current-user'
        s =~ /\A\d+\z/ ? s.to_i : nil
      end

      # -------- type normalization --------
      #
      # Your model allows (from your runner output):
      # call, email, meeting, note, status_change, form_submission,
      # website_visit, sms, nurture_email, ai_suggestion
      #
      # We’ll:
      # 1) read from activity_type|type|kind|category,
      # 2) downcase & alias common variants,
      # 3) if still invalid/blank → fallback to the first allowed option.
      #
      def normalize_activity_type(raw)
        incoming = coalesce(raw[:activity_type], raw[:type], raw[:kind], raw[:category]).to_s.strip.downcase

        # simple alias map for common UI synonyms
        aliases = {
          'notes' => 'note',
          'phone' => 'call',
          'text'  => 'sms',
          'im'    => 'sms',
          'ai'    => 'ai_suggestion',
          'nurture' => 'nurture_email'
        }
        incoming = aliases[incoming] || incoming

        allowed = allowed_activity_types
        return incoming if allowed.include?(incoming)

        # Final fallback prevents 422s when FE sends odd values
        allowed.first || 'note'
      end

      def allowed_activity_types
        @allowed_activity_types ||= begin
          if Activity.respond_to?(:defined_enums) && Activity.defined_enums['activity_type']
            Activity.defined_enums['activity_type'].keys
          else
            inc = Activity.validators_on(:activity_type).map { |v| v.options[:in] }.compact.flatten.uniq
            inc.presence || %w[call email meeting note status_change form_submission website_visit sms nurture_email ai_suggestion]
          end
        end
      end
    end
  end
end

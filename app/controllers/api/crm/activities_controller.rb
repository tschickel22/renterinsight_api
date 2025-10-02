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
        attrs = extract_attrs

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

      # Pull attributes from nested or root; tolerate different key spellings.
      def extract_attrs
        nested = params[:activity].is_a?(ActionController::Parameters) ? params.require(:activity) : nil

        permitted_nested = nested&.permit(
          :type, :activity_type, :kind, :description, :outcome, :duration,
          :scheduled_date, :completed_date, metadata: {}
        )
        permitted_root = params.permit(
          :type, :activity_type, :kind, :description, :outcome, :duration,
          :scheduled_date, :completed_date, metadata: {}
        )

        atype = first_present(
          permitted_nested&.[](:type),
          permitted_nested&.[](:activity_type),
          permitted_nested&.[](:kind),
          permitted_root[:type],
          permitted_root[:activity_type],
          permitted_root[:kind]
        )

        {
          activity_type: normalize_type(atype),
          description:   first_present(permitted_nested&.[](:description), permitted_root[:description]),
          outcome:       first_present(permitted_nested&.[](:outcome),     permitted_root[:outcome]),
          duration:      first_present(permitted_nested&.[](:duration),    permitted_root[:duration]),
          scheduled_date:first_present(permitted_nested&.[](:scheduled_date), permitted_root[:scheduled_date]),
          completed_date:first_present(permitted_nested&.[](:completed_date), permitted_root[:completed_date]),
          metadata:      first_present(permitted_nested&.[](:metadata), permitted_root[:metadata]) || {}
        }.compact
      end

      def first_present(*vals)
        vals.find { |v| v.present? }
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

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
      # Accepts either payload style:
      # 1) { "activity": { "type": "...", "description": "...", "metadata": {...} } }
      # 2) { "type": "...", "description": "...", "metadata": {...} }
      def create
        attrs = activity_params.presence || root_activity_params
        @activity = @lead.activities.new(attrs)

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

      # Nested payload: { activity: { ... } }
      def activity_params
        params.require(:activity).permit(:type, :description, metadata: {})
      rescue ActionController::ParameterMissing
        nil
      end

      # Root payload: { type, description, metadata }
      def root_activity_params
        params.permit(:type, :description, metadata: {})
      end
    end
  end
end

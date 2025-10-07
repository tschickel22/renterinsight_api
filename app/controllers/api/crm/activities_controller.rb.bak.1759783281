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
      def create
        attrs = activity_params
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

      def activity_params
        params.require(:activity).permit(
          :activity_type,
          :description,
          :outcome,
          :duration,
          :scheduled_date,
          :user_id,
          metadata: {}
        )
      end
    end
  end
end

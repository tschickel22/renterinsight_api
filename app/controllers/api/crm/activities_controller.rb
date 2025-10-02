module Api
  module Crm
    class ActivitiesController < ApplicationController
      skip_before_action :verify_authenticity_token, raise: false
      before_action :set_lead

      rescue_from ActiveRecord::RecordNotFound do
        render json: { error: 'not_found' }, status: :not_found
      end

      rescue_from ActionController::ParameterMissing do |e|
        render json: { error: 'bad_request', message: e.message }, status: :unprocessable_entity
      end

      def index
        activities = @lead.activities.order(created_at: :desc)
        render json: activities.map { |a| activity_json(a) }
      end

      def create
        p = extract_payload

        attrs = {
          activity_type:  p[:type],
          description:    p[:description],
          outcome:        p[:outcome],
          duration:       p[:duration],
          scheduled_date: p[:scheduled_date],
          completed_date: p[:completed_date],
          metadata:       p[:metadata] || {}
        }.compact

        activity = @lead.activities.new(attrs)

        # only set user_id if there's a users table AND the id exists
        if (uid = candidate_user_id).present? && users_table_exists? && User.where(id: uid).exists?
          activity.user_id = uid
        end

        if activity.save
          render json: activity_json(activity), status: :created
        else
          render json: { errors: activity.errors.full_messages }, status: :unprocessable_entity
        end
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id] || params[:id] || params[:leadId])
      end

      def extract_payload
        if params[:activity].present?
          params.require(:activity).permit(

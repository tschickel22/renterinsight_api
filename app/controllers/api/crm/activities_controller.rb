# frozen_string_literal: true
module Api
  module Crm
    class ActivitiesController < ApplicationController
      before_action :set_lead
      before_action :set_activity, only: [:update, :destroy]

      # GET /api/crm/leads/:lead_id/activities
      def index
        activities = @lead.activities.order(created_at: :desc)
        render json: activities.map { |a| activity_json(a) }, status: :ok
      end

      # POST /api/crm/leads/:lead_id/activities
      def create
        attrs = normalize_activity_params
        Rails.logger.info "[ActivitiesController#create] Normalized attrs: #{attrs.inspect}"
        Rails.logger.info "[ActivitiesController#create] Lead: #{@lead.id}, Lead exists: #{@lead.persisted?}"
        
        # Get user_id outside of activity creation
        user_id = attrs[:user_id] || User.first&.id
        Rails.logger.info "[ActivitiesController#create] Using user_id: #{user_id}"
        
        unless user_id
          render json: { error: 'No users available in system' }, status: :unprocessable_entity
          return
        end
        
        activity = @lead.activities.build(attrs)
        activity.user_id = user_id
        
        Rails.logger.info "[ActivitiesController#create] Activity before save: lead_id=#{activity.lead_id}, user_id=#{activity.user_id}, type=#{activity.activity_type}, description=#{activity.description}"

        if activity.save
          Rails.logger.info "[ActivitiesController#create] Activity saved successfully with id=#{activity.id}"
          render json: activity_json(activity), status: :created
        else
          Rails.logger.error "[ActivitiesController#create] Validation failed: #{activity.errors.full_messages}"
          render json: { errors: activity.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[ActivitiesController#create] Exception: #{e.class}: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        render json: { error: 'Server error creating activity', message: e.message, details: e.class.to_s }, status: :internal_server_error
      end

      # PATCH /api/crm/leads/:lead_id/activities/:id
      def update
        attrs = normalize_activity_params
        if @activity.update(attrs)
          render json: activity_json(@activity), status: :ok
        else
          render json: { errors: @activity.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/crm/leads/:lead_id/activities/:id
      def destroy
        @activity.destroy!
        head :no_content
      rescue => e
        Rails.logger.error "[ActivitiesController#destroy] #{e.class}: #{e.message}"
        render json: { error: 'Server error deleting activity', message: e.message }, status: :internal_server_error
      end

      private

      def set_lead
        @lead = Lead.find(params[:lead_id])
      end

      def set_activity
        @activity = Activity.find(params[:id])
      end

      def normalize_activity_params
        raw = if params[:activity].present?
          params.require(:activity).permit(
            :activity_type, :type, :description, :outcome, :duration,
            :scheduled_date, :completed_date, :user_id, metadata: {}
          ).to_h
        else
          params.permit(
            :activity_type, :type, :description, :outcome, :duration,
            :scheduled_date, :completed_date, :user_id, metadata: {}
          ).to_h
        end

        atype = raw[:activity_type].presence || raw[:type].presence

        {
          activity_type: atype,
          description: raw[:description],
          outcome: raw[:outcome],
          duration: raw[:duration],
          scheduled_date: raw[:scheduled_date],
          completed_date: raw[:completed_date],
          user_id: raw[:user_id],
          metadata: (raw[:metadata].presence || {})
        }.compact
      end

      def activity_json(activity)
        {
          id: activity.id,
          leadId: activity.lead_id,
          userId: activity.user_id,
          type: activity.activity_type,
          description: activity.description,
          outcome: activity.outcome,
          duration: activity.duration,
          scheduledDate: activity.scheduled_date&.iso8601,
          completedDate: activity.completed_date&.iso8601,
          metadata: activity.metadata || {},
          createdAt: activity.created_at&.iso8601,
          updatedAt: activity.updated_at&.iso8601
        }.compact
      end

      # Ensure a default user exists for activities
      def get_or_create_system_user
        # First, check if any user exists
        existing_user = User.first
        return existing_user.id if existing_user
        
        # No users exist - try to create one outside of the activity transaction
        Rails.logger.info "[ActivitiesController] No users found, creating system user"
        
        begin
          # Create in a separate transaction
          user = nil
          User.transaction do
            user = User.create!(
              email: 'system@example.com',
              name: 'System User'
            )
          end
          Rails.logger.info "[ActivitiesController] Created system user with id=#{user.id}"
          return user.id
        rescue => e
          Rails.logger.error "[ActivitiesController] Failed to create system user: #{e.message}"
          Rails.logger.error e.backtrace.first(5).join("\n")
          raise "Cannot create activity: No users available and failed to create default user (#{e.message})"
        end
      end
    end
  end
end

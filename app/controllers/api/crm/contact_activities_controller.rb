# frozen_string_literal: true

module Api
  module Crm
    class ContactActivitiesController < ApplicationController
      before_action :set_contact
      before_action :set_activity, only: [:show, :update, :complete, :cancel, :destroy]
      
      # GET /api/crm/contacts/:contact_id/activities
      def index
        # Get activities directly for this contact
        activities = @contact.contact_activities
                             .includes(:user, :assigned_to)
                             .order(Arel.sql('COALESCE(due_date, start_time, created_at) ASC'))
        
        # If contact is linked to an account, also include account activities
        if @contact.account_id.present?
          account_activities = AccountActivity.where(account_id: @contact.account_id)
                                               .includes(:user, :assigned_to)
          # Merge and sort all activities
          all_activities = (activities.to_a + account_activities.to_a)
                            .sort_by { |a| a.due_date || a.start_time || a.created_at }
          activities = all_activities
        end
        
        # Filter by type if provided
        activities = activities.select { |a| a.activity_type == params[:type] } if params[:type].present?
        # Filter by status
        activities = activities.select { |a| a.status == params[:status] } if params[:status].present?
        # Filter by assigned user
        activities = activities.select { |a| a.assigned_to_id.to_s == params[:assigned_to].to_s } if params[:assigned_to].present?
        
        render json: activities.map { |a| activity_json(a) }, status: :ok
      rescue => e
        Rails.logger.error "[ContactActivitiesController#index] #{e.class}: #{e.message}"
        render json: { error: 'Failed to load activities', message: e.message }, status: :internal_server_error
      end
      
      # GET /api/crm/contacts/:contact_id/activities/:id
      def show
        render json: activity_json(@activity), status: :ok
      end
      
      # POST /api/crm/contacts/:contact_id/activities
      def create
        Rails.logger.info "[ContactActivitiesController#create] Starting create with params: #{params.inspect}"
        
        @activity = @contact.contact_activities.build(activity_params)
        @activity.user = current_user_or_first
        @activity.assigned_to ||= current_user_or_first
        
        Rails.logger.info "[ContactActivitiesController#create] Built activity: #{@activity.attributes.inspect}"

        if @activity.save
          Rails.logger.info "[ContactActivitiesController#create] Activity saved successfully with id=#{@activity.id}"
          render json: activity_json(@activity), status: :created
        else
          Rails.logger.error "[ContactActivitiesController#create] Validation failed: #{@activity.errors.full_messages}"
          render json: { errors: @activity.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[ContactActivitiesController#create] #{e.class}: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        render json: { error: 'Failed to create activity', message: e.message, details: e.class.to_s }, status: :internal_server_error
      end
      
      # PATCH /api/crm/contacts/:contact_id/activities/:id
      def update
        if @activity.update(activity_params)
          render json: activity_json(@activity), status: :ok
        else
          render json: { errors: @activity.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[ContactActivitiesController#update] #{e.class}: #{e.message}"
        render json: { error: 'Failed to update activity', message: e.message }, status: :internal_server_error
      end
      
      # POST /api/crm/contacts/:contact_id/activities/:id/complete
      def complete
        @activity.complete!
        render json: activity_json(@activity), status: :ok
      rescue => e
        Rails.logger.error "[ContactActivitiesController#complete] #{e.class}: #{e.message}"
        render json: { error: 'Failed to complete activity', message: e.message }, status: :internal_server_error
      end
      
      # POST /api/crm/contacts/:contact_id/activities/:id/cancel
      def cancel
        @activity.cancel!
        render json: activity_json(@activity), status: :ok
      rescue => e
        Rails.logger.error "[ContactActivitiesController#cancel] #{e.class}: #{e.message}"
        render json: { error: 'Failed to cancel activity', message: e.message }, status: :internal_server_error
      end
      
      # DELETE /api/crm/contacts/:contact_id/activities/:id
      def destroy
        @activity.destroy!
        head :no_content
      rescue => e
        Rails.logger.error "[ContactActivitiesController#destroy] #{e.class}: #{e.message}"
        render json: { error: 'Failed to delete activity', message: e.message }, status: :internal_server_error
      end
      
      private
      
      def set_contact
        @contact = Contact.find(params[:contact_id])
      end
      
      def set_activity
        @activity = @contact.contact_activities.find(params[:id])
      end
      
      def current_user_or_first
        # In production, use actual current_user from authentication
        # For now, use first user
        User.first
      end
      
      def activity_params
        raw = if params[:activity].present?
                params.require(:activity).permit(
                  :activity_type, :subject, :description, :status, :priority,
                  :due_date, :start_time, :end_time, :duration_minutes,
                  :call_direction, :call_outcome, :phone_number,
                  :meeting_location, :meeting_link, :meeting_attendees,
                  :estimated_hours, :actual_hours, :outcome_notes,
                  :related_activity_id, :assigned_to_id, :reminder_time,
                  reminder_method: [], metadata: {}
                )
              else
                params.permit(
                  :activity_type, :activityType, :subject, :description, :status, :priority,
                  :due_date, :dueDate, :start_time, :startTime, :end_time, :endTime,
                  :duration_minutes, :durationMinutes,
                  :call_direction, :callDirection, :call_outcome, :callOutcome,
                  :phone_number, :phoneNumber,
                  :meeting_location, :meetingLocation, :meeting_link, :meetingLink,
                  :meeting_attendees, :meetingAttendees,
                  :estimated_hours, :estimatedHours, :actual_hours, :actualHours,
                  :outcome_notes, :outcomeNotes,
                  :related_activity_id, :relatedActivityId,
                  :assigned_to_id, :assignedToId,
                  :reminder_time, :reminderTime,
                  reminder_method: [], reminderMethod: [], metadata: {}
                )
              end
        
        # Normalize camelCase to snake_case
        normalized = {
          activity_type: raw[:activity_type] || raw[:activityType],
          subject: raw[:subject],
          description: raw[:description],
          status: raw[:status],
          priority: raw[:priority],
          due_date: parse_time(raw[:due_date] || raw[:dueDate]),
          start_time: parse_time(raw[:start_time] || raw[:startTime]),
          end_time: parse_time(raw[:end_time] || raw[:endTime]),
          duration_minutes: raw[:duration_minutes] || raw[:durationMinutes],
          call_direction: raw[:call_direction] || raw[:callDirection],
          call_outcome: raw[:call_outcome] || raw[:callOutcome],
          phone_number: raw[:phone_number] || raw[:phoneNumber],
          meeting_location: raw[:meeting_location] || raw[:meetingLocation],
          meeting_link: raw[:meeting_link] || raw[:meetingLink],
          meeting_attendees: raw[:meeting_attendees] || raw[:meetingAttendees],
          reminder_time: parse_time(raw[:reminder_time] || raw[:reminderTime]),
          estimated_hours: raw[:estimated_hours] || raw[:estimatedHours],
          actual_hours: raw[:actual_hours] || raw[:actualHours],
          outcome_notes: raw[:outcome_notes] || raw[:outcomeNotes],
          related_activity_id: raw[:related_activity_id] || raw[:relatedActivityId],
          assigned_to_id: raw[:assigned_to_id] || raw[:assignedToId],
          metadata: raw[:metadata] || {}
        }.compact
        
        # Handle reminder_method specially - ensure it's an array
        reminder_method_value = raw[:reminder_method] || raw[:reminderMethod]
        if reminder_method_value.present?
          if reminder_method_value.is_a?(Array)
            normalized[:reminder_method] = reminder_method_value
          elsif reminder_method_value.is_a?(String)
            normalized[:reminder_method] = JSON.parse(reminder_method_value) rescue [reminder_method_value]
          end
        end
        
        normalized
      end
      
      def activity_json(activity)
        # Handle both ContactActivity and AccountActivity
        json = {
          id: activity.id,
          userId: activity.user_id,
          assignedToId: activity.assigned_to_id,
          assignedTo: activity.assigned_to ? {
            id: activity.assigned_to.id,
            name: activity.assigned_to.name,
            email: activity.assigned_to.email
          } : nil,
          activityType: activity.activity_type,
          subject: activity.subject,
          description: activity.description,
          status: activity.status,
          priority: activity.priority,
          dueDate: activity.due_date&.iso8601,
          startTime: activity.start_time&.iso8601,
          endTime: activity.end_time&.iso8601,
          durationMinutes: activity.duration_minutes,
          completedAt: activity.completed_at&.iso8601,
          callDirection: activity.call_direction,
          callOutcome: activity.call_outcome,
          phoneNumber: activity.phone_number,
          meetingLocation: activity.meeting_location,
          meetingLink: activity.meeting_link,
          meetingAttendees: activity.meeting_attendees,
          reminderMethod: activity.reminder_method,
          reminderTime: activity.reminder_time&.iso8601,
          reminderSent: activity.reminder_sent,
          estimatedHours: activity.estimated_hours,
          actualHours: activity.actual_hours,
          outcomeNotes: activity.outcome_notes,
          relatedActivityId: activity.related_activity_id,
          metadata: activity.metadata,
          overdue: activity.overdue?,
          createdAt: activity.created_at&.iso8601,
          updatedAt: activity.updated_at&.iso8601
        }
        
        # Add entity-specific IDs
        if activity.is_a?(ContactActivity)
          json[:contactId] = activity.contact_id
          json[:accountId] = activity.account_id
          json[:source] = 'contact'
        elsif activity.is_a?(AccountActivity)
          json[:accountId] = activity.account_id
          json[:source] = 'account'
        end
        
        json.compact
      end
      
      def parse_time(value)
        return nil if value.blank?
        Time.zone.parse(value.to_s)
      rescue
        nil
      end
    end
  end
end

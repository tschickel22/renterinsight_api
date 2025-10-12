module Api
  module V1
    class AccountActivitiesController < ApplicationController
      before_action :set_account, except: [:mark_reminder_sent]
      before_action :set_activity, only: [:show, :update, :complete, :cancel, :destroy]

      # GET /api/v1/accounts/:account_id/activities
      def index
        activities = @account.activities
                             .includes(:user, :assigned_to)
                             .order(Arel.sql('COALESCE(due_date, start_time, created_at) ASC'))
        
        # Filter by type if provided
        activities = activities.where(activity_type: params[:type]) if params[:type].present?
        # Filter by status
        activities = activities.where(status: params[:status]) if params[:status].present?
        # Filter by assigned user
        activities = activities.where(assigned_to_id: params[:assigned_to]) if params[:assigned_to].present?
        
        render json: activities.map { |a| activity_json(a) }, status: :ok
      rescue => e
        Rails.logger.error "[AccountActivitiesController#index] #{e.class}: #{e.message}"
        render json: { error: 'Failed to load activities', message: e.message }, status: :internal_server_error
      end

      # GET /api/v1/accounts/:account_id/activities/:id
      def show
        render json: activity_json(@activity), status: :ok
      end

      # POST /api/v1/accounts/:account_id/activities
      def create
        Rails.logger.info "[AccountActivitiesController#create] Starting create with params: #{params.inspect}"
        
        @activity = @account.activities.build(activity_params)
        @activity.user = current_user_or_first
        @activity.assigned_to ||= current_user_or_first
        
        Rails.logger.info "[AccountActivitiesController#create] Built activity: #{@activity.attributes.inspect}"

        if @activity.save
          Rails.logger.info "[AccountActivitiesController#create] Activity saved successfully with id=#{@activity.id}"
          render json: activity_json(@activity), status: :created
        else
          Rails.logger.error "[AccountActivitiesController#create] Validation failed: #{@activity.errors.full_messages}"
          render json: { errors: @activity.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[AccountActivitiesController#create] #{e.class}: #{e.message}"
        Rails.logger.error e.backtrace.first(10).join("\n")
        render json: { error: 'Failed to create activity', message: e.message, details: e.class.to_s }, status: :internal_server_error
      end

      # PATCH/PUT /api/v1/accounts/:account_id/activities/:id
      def update
        if @activity.update(activity_params)
          render json: activity_json(@activity), status: :ok
        else
          render json: { errors: @activity.errors.full_messages }, status: :unprocessable_entity
        end
      rescue => e
        Rails.logger.error "[AccountActivitiesController#update] #{e.class}: #{e.message}"
        render json: { error: 'Failed to update activity', message: e.message }, status: :internal_server_error
      end

      # POST /api/v1/accounts/:account_id/activities/:id/complete
      def complete
        @activity.complete!
        render json: activity_json(@activity), status: :ok
      rescue => e
        Rails.logger.error "[AccountActivitiesController#complete] #{e.class}: #{e.message}"
        render json: { error: 'Failed to complete activity', message: e.message }, status: :internal_server_error
      end
      
      # POST /api/v1/accounts/:account_id/activities/:id/cancel
      def cancel
        @activity.cancel!
        render json: activity_json(@activity), status: :ok
      rescue => e
        Rails.logger.error "[AccountActivitiesController#cancel] #{e.class}: #{e.message}"
        render json: { error: 'Failed to cancel activity', message: e.message }, status: :internal_server_error
      end

      # DELETE /api/v1/accounts/:account_id/activities/:id
      def destroy
        @activity.destroy!
        head :no_content
      rescue => e
        Rails.logger.error "[AccountActivitiesController#destroy] #{e.class}: #{e.message}"
        render json: { error: 'Failed to delete activity', message: e.message }, status: :internal_server_error
      end

      # GET /api/v1/accounts/:account_id/activities/reminders
      def reminders
        activities = @account.activities
                             .where(status: 'pending')
                             .where.not(reminder_time: nil)
                             .where(reminder_sent: [false, nil])
                             .where('reminder_time <= ?', Time.current)
                             .includes(:user, :assigned_to, :account)
                             .order(reminder_time: :asc)
        
        render json: activities.map { |a| activity_json(a) }, status: :ok
      rescue => e
        Rails.logger.error "[AccountActivitiesController#reminders] #{e.class}: #{e.message}"
        render json: { error: 'Failed to load reminders', message: e.message }, status: :internal_server_error
      end

      # POST /api/v1/account_activities/:id/mark_reminder_sent
      def mark_reminder_sent
        activity = AccountActivity.find(params[:id])
        activity.update!(reminder_sent: true)
        render json: activity_json(activity), status: :ok
      rescue => e
        Rails.logger.error "[AccountActivitiesController#mark_reminder_sent] #{e.class}: #{e.message}"
        render json: { error: 'Failed to mark reminder as sent', message: e.message }, status: :internal_server_error
      end

      private

      def set_account
        @account = Account.find(params[:account_id])
      end

      def set_activity
        @activity = @account.activities.find(params[:id])
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
                  :due_date, :start_time, :end_time, :duration_minutes, :duration,
                  :scheduled_date, :call_direction, :call_outcome, :phone_number,
                  :meeting_location, :meeting_link, :meeting_attendees,
                  :estimated_hours, :actual_hours, :outcome_notes, :outcome,
                  :related_activity_id, :assigned_to_id, :reminder_time,
                  reminder_method: [], metadata: {}
                )
              else
                params.permit(
                  :activity_type, :activityType, :type, :subject, :description, :status, :priority,
                  :due_date, :dueDate, :start_time, :startTime, :end_time, :endTime,
                  :duration_minutes, :durationMinutes, :duration, :scheduled_date, :scheduledDate,
                  :call_direction, :callDirection, :call_outcome, :callOutcome,
                  :phone_number, :phoneNumber,
                  :meeting_location, :meetingLocation, :meeting_link, :meetingLink,
                  :meeting_attendees, :meetingAttendees,
                  :estimated_hours, :estimatedHours, :actual_hours, :actualHours,
                  :outcome_notes, :outcomeNotes, :outcome,
                  :related_activity_id, :relatedActivityId,
                  :assigned_to_id, :assignedToId,
                  :reminder_time, :reminderTime,
                  reminder_method: [], reminderMethod: [], metadata: {}
                )
              end
        
        # Normalize camelCase to snake_case
        normalized = {
          activity_type: raw[:activity_type] || raw[:activityType] || raw[:type],
          subject: raw[:subject],
          description: raw[:description],
          status: raw[:status],
          priority: raw[:priority],
          due_date: parse_time(raw[:due_date] || raw[:dueDate]),
          scheduled_date: parse_time(raw[:scheduled_date] || raw[:scheduledDate]),
          start_time: parse_time(raw[:start_time] || raw[:startTime]),
          end_time: parse_time(raw[:end_time] || raw[:endTime]),
          duration_minutes: raw[:duration_minutes] || raw[:durationMinutes],
          duration: raw[:duration],
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
          outcome: raw[:outcome],
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
        {
          id: activity.id,
          accountId: activity.account_id,
          account: activity.account ? {
            id: activity.account.id,
            name: activity.account.name
          } : nil,
          userId: activity.user_id,
          assignedToId: activity.assigned_to_id,
          assignedTo: activity.assigned_to ? {
            id: activity.assigned_to.id,
            name: activity.assigned_to.name,
            email: activity.assigned_to.email
          } : nil,
          activityType: activity.activity_type,
          type: activity.activity_type, # For backward compatibility
          subject: activity.subject,
          description: activity.description,
          status: activity.status,
          priority: activity.priority,
          dueDate: activity.due_date&.iso8601,
          scheduledDate: activity.scheduled_date&.iso8601,
          startTime: activity.start_time&.iso8601,
          endTime: activity.end_time&.iso8601,
          durationMinutes: activity.duration_minutes,
          duration: activity.duration,
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
          outcome: activity.outcome,
          relatedActivityId: activity.related_activity_id,
          metadata: activity.metadata,
          overdue: activity.overdue?,
          createdAt: activity.created_at&.iso8601,
          updatedAt: activity.updated_at&.iso8601
        }.compact
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

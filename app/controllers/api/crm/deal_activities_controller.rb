# frozen_string_literal: true

module Api
  module Crm
    class DealActivitiesController < ApplicationController
      include RbacAuthorization
      rbac_resource :crm

      before_action :set_company_scope
      before_action :set_deal
      before_action :set_activity, only: [:show, :update, :destroy, :complete, :cancel]

      # GET /api/crm/deals/:deal_id/deal_activities
      def index
        activities = @deal.activities.order(created_at: :desc)

        # Task privacy: non-admins only see task-type activities they're
        # assigned to. The `activities` table uses namespaced strings
        # (e.g. 'lead_activity_task'), so match either the bare or
        # namespaced form for portability across the two schemas.
        unless current_user.effective_admin? || params[:view] == 'all'
          activities = activities.where(
            "activity_type NOT IN ('task', 'lead_activity_task') OR assigned_to_id = ?",
            current_user.id
          )
        end

        render json: activities.map { |a| activity_json(a) }, status: :ok
      end

      # GET /api/crm/deals/:deal_id/deal_activities/:id
      def show
        render json: activity_json(@activity), status: :ok
      end

      # POST /api/crm/deals/:deal_id/deal_activities
      def create
        activity = @deal.activities.build(activity_params)
        activity.user = current_user

        if activity.save
          render json: activity_json(activity), status: :created
        else
          render json: { errors: activity.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH/PUT /api/crm/deals/:deal_id/deal_activities/:id
      def update
        if @activity.update(activity_params)
          render json: activity_json(@activity), status: :ok
        else
          render json: { errors: @activity.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/crm/deals/:deal_id/deal_activities/:id
      def destroy
        @activity.destroy
        head :no_content
      end

      # POST /api/crm/deals/:deal_id/deal_activities/:id/complete
      def complete
        @activity.complete!
        render json: activity_json(@activity), status: :ok
      end

      # POST /api/crm/deals/:deal_id/deal_activities/:id/cancel
      def cancel
        @activity.cancel!
        render json: activity_json(@activity), status: :ok
      end

      # GET /api/crm/deals/:deal_id/deal_activities/reminders
      def reminders
        upcoming_reminders = @deal.activities
          .where(activity_type: 'reminder')
          .where('reminder_time > ? AND reminder_time <= ?', Time.current, 5.minutes.from_now)
          .where('reminder_sent = ? OR reminder_sent IS NULL', false)
          .order(reminder_time: :asc)

        render json: upcoming_reminders.map { |a| activity_json(a) }, status: :ok
      end

      # POST /api/crm/deal_activities/:id/mark_reminder_sent
      def mark_reminder_sent
        activity = @company.deals.joins(:activities)
          .find_by!('deal_activities.id': params[:id])
          .activities.find(params[:id])
        
        activity.update!(reminder_sent: true)
        head :no_content
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Activity not found' }, status: :not_found
      end

      private

      def set_company_scope
        unless current_user
          render json: { error: 'Authentication required' }, status: :unauthorized
          return
        end

        company_id = current_company_id

        unless company_id.present?
          render json: { error: 'No company context' }, status: :forbidden
          return
        end

        @company = ::Company.find_by(id: company_id)

        if @company.nil?
          render json: { error: 'Company not found' }, status: :not_found
          return
        end
      end

      def set_deal
        @deal = @company.deals.find(params[:deal_id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Deal not found' }, status: :not_found
      end

      def set_activity
        @activity = @deal.activities.find(params[:id])
      rescue ActiveRecord::RecordNotFound
        render json: { error: 'Activity not found' }, status: :not_found
      end

      def activity_params
        params.require(:deal_activity).permit(
          :activity_type,
          :subject,
          :description,
          :status,
          :priority,
          :due_date,
          :start_time,
          :end_time,
          :assigned_to_id,
          :phone_number,
          :call_direction,
          :call_outcome,
          :duration,
          :location,
          :meeting_link,
          :attendees,
          :outcome,
          :reminder_time,
          :related_activity_id,
          reminder_method: []
        )
      end

      def activity_json(activity)
        {
          id: activity.id,
          dealId: activity.deal_id,
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
          completedAt: activity.completed_at&.iso8601,
          phoneNumber: activity.phone_number,
          callDirection: activity.call_direction,
          callOutcome: activity.call_outcome,
          duration: activity.duration,
          meetingLocation: activity.location,
          meetingLink: activity.meeting_link,
          meetingAttendees: activity.attendees,
          outcomeNotes: activity.outcome,
          reminderTime: activity.reminder_time&.iso8601,
          reminderMethod: activity.reminder_method,
          reminderSent: activity.reminder_sent,
          createdAt: activity.created_at&.iso8601,
          updatedAt: activity.updated_at&.iso8601
        }
      end
    end
  end
end

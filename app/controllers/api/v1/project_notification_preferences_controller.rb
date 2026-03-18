# frozen_string_literal: true

module Api
  module V1
    class ProjectNotificationPreferencesController < ApplicationController
      before_action :set_company_scope
      before_action :set_project

      # GET /api/v1/projects/:project_id/notification_preferences
      def index
        return unless authorize_action!('projects', 'read')

        prefs = @project.notification_preferences.includes(:recipient)

        render json: prefs.map { |p| pref_json(p) }
      end

      # POST /api/v1/projects/:project_id/notification_preferences
      def create
        return unless authorize_action!('projects', 'update')

        pref = @project.notification_preferences.build(pref_params)
        pref.company = @company

        if pref.recipient_email.blank? && pref.recipient
          pref.recipient_email = pref.recipient.try(:email)
        end
        if pref.recipient_phone.blank? && pref.recipient
          pref.recipient_phone = pref.recipient.try(:phone) || pref.recipient.try(:mobile_phone)
        end

        if pref.save
          render json: pref_json(pref), status: :created
        else
          render json: { errors: pref.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # PATCH /api/v1/projects/:project_id/notification_preferences/:id
      def update
        return unless authorize_action!('projects', 'update')

        pref = @project.notification_preferences.find(params[:id])

        if pref.update(pref_params)
          render json: pref_json(pref)
        else
          render json: { errors: pref.errors.full_messages }, status: :unprocessable_entity
        end
      end

      # DELETE /api/v1/projects/:project_id/notification_preferences/:id
      def destroy
        return unless authorize_action!('projects', 'update')
        pref = @project.notification_preferences.find(params[:id])
        pref.destroy
        render json: { message: 'Preference removed' }
      end

      # POST /api/v1/projects/:project_id/notification_preferences/auto_setup
      def auto_setup
        return unless authorize_action!('projects', 'update')

        created = []

        # Add deal contacts (buyers)
        if @project.deal.present?
          @project.deal.contacts.each do |contact|
            next if @project.notification_preferences.exists?(recipient_type: 'Contact', recipient_id: contact.id)

            pref = @project.notification_preferences.create!(
              company: @company,
              recipient_type: 'Contact',
              recipient_id: contact.id,
              recipient_email: contact.email,
              recipient_phone: contact.phone || contact.mobile_phone,
              notify_phase_started: true,
              notify_phase_completed: true,
              notify_milestone_reached: true,
              notify_payment_due: true,
              via_email: true,
              via_sms: contact.phone.present? || contact.mobile_phone.present?
            )
            created << pref
          end
        end

        # Add the deal owner / salesperson
        if @project.deal&.user.present?
          user = @project.deal.user
          unless @project.notification_preferences.exists?(recipient_type: 'User', recipient_id: user.id)
            pref = @project.notification_preferences.create!(
              company: @company,
              recipient_type: 'User',
              recipient_id: user.id,
              recipient_email: user.email,
              notify_phase_started: true,
              notify_phase_completed: true,
              notify_task_assigned: true,
              notify_task_completed: true,
              notify_inspection_passed: true,
              notify_inspection_failed: true,
              via_email: true,
              via_sms: false
            )
            created << pref
          end
        end

        render json: {
          message: "Created #{created.count} notification preferences",
          preferences: created.map { |p| pref_json(p) }
        }
      end

      private

      def set_project
        @project = @company.projects.find(params[:project_id])
      end

      def pref_params
        params.require(:preference).permit(
          :recipient_type, :recipient_id, :recipient_email, :recipient_phone,
          :notify_phase_started, :notify_phase_completed,
          :notify_task_assigned, :notify_task_completed,
          :notify_inspection_scheduled, :notify_inspection_passed, :notify_inspection_failed,
          :notify_milestone_reached, :notify_payment_due, :notify_daily_summary,
          :via_email, :via_sms, :is_active
        )
      end

      def pref_json(pref)
        {
          id: pref.id,
          recipientType: pref.recipient_type,
          recipientId: pref.recipient_id,
          recipientName: recipient_name(pref),
          recipientEmail: pref.effective_email,
          recipientPhone: pref.effective_phone,
          notifyPhaseStarted: pref.notify_phase_started,
          notifyPhaseCompleted: pref.notify_phase_completed,
          notifyTaskAssigned: pref.notify_task_assigned,
          notifyTaskCompleted: pref.notify_task_completed,
          notifyInspectionScheduled: pref.notify_inspection_scheduled,
          notifyInspectionPassed: pref.notify_inspection_passed,
          notifyInspectionFailed: pref.notify_inspection_failed,
          notifyMilestoneReached: pref.notify_milestone_reached,
          notifyPaymentDue: pref.notify_payment_due,
          notifyDailySummary: pref.notify_daily_summary,
          viaEmail: pref.via_email,
          viaSms: pref.via_sms,
          isActive: pref.is_active
        }
      end

      def recipient_name(pref)
        case pref.recipient_type
        when 'User'
          user = User.find_by(id: pref.recipient_id)
          user ? "#{user.first_name} #{user.last_name}" : 'Unknown User'
        when 'Contact'
          contact = Contact.find_by(id: pref.recipient_id)
          contact ? "#{contact.first_name} #{contact.last_name}" : 'Unknown Contact'
        else
          'Unknown'
        end
      end
    end
  end
end

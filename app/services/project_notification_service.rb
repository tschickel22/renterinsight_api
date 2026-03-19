# frozen_string_literal: true

class ProjectNotificationService
  # Called when a project phase status changes
  def self.notify_phase_change(phase, old_status, new_status)
    return if old_status == new_status

    project = phase.project
    company = project.company

    event = case new_status
            when 'in_progress' then 'phase_started'
            when 'completed' then 'phase_completed'
            else return
            end

    prefs = project.notification_preferences.active.for_event(event)

    prefs.each do |pref|
      if pref.via_email && pref.effective_email.present?
        send_email_notification(
          company: company,
          project: project,
          phase: phase,
          event: event,
          recipient_email: pref.effective_email,
          recipient_name: recipient_display_name(pref),
          user: find_sending_user(project)
        )
      end

      if pref.via_sms && pref.effective_phone.present?
        send_sms_notification(
          company: company,
          project: project,
          phase: phase,
          event: event,
          recipient_phone: pref.effective_phone,
          user: find_sending_user(project)
        )
      end
    end
  end

  # Called when a task is completed
  def self.notify_task_completed(task)
    project = task.project

    prefs = project.notification_preferences.active.for_event('task_completed')

    prefs.each do |pref|
      if pref.via_email && pref.effective_email.present?
        send_email_notification(
          company: task.company,
          project: project,
          phase: task.project_phase,
          task: task,
          event: 'task_completed',
          recipient_email: pref.effective_email,
          recipient_name: recipient_display_name(pref),
          user: find_sending_user(project)
        )
      end
    end
  end

  # Called when a task is assigned
  def self.notify_task_assigned(task, assignee)
    project = task.project

    prefs = project.notification_preferences.active.for_event('task_assigned')
      .where(recipient_type: assignee.class.name, recipient_id: assignee.id)

    prefs.each do |pref|
      if pref.via_email && pref.effective_email.present?
        send_email_notification(
          company: task.company,
          project: project,
          phase: task.project_phase,
          task: task,
          event: 'task_assigned',
          recipient_email: pref.effective_email,
          recipient_name: recipient_display_name(pref),
          user: find_sending_user(project)
        )
      end
    end
  end

  class << self
    private

    def send_email_notification(company:, project:, phase:, event:, recipient_email:, recipient_name:, user: nil, task: nil)
      subject = build_subject(project, phase, event, task)
      body = build_body(project, phase, event, recipient_name, task)

      CommunicationService.send_email(
        company: company,
        user: user,
        location: project.deal&.location,
        to: recipient_email,
        subject: subject,
        body: body,
        category: 'project_notification',
        communicable: project
      )
    rescue => e
      Rails.logger.error("[ProjectNotification] Email failed: #{e.message}")
    end

    def send_sms_notification(company:, project:, phase:, event:, recipient_phone:, user: nil)
      message = build_sms_message(project, phase, event)

      CommunicationService.send_sms(
        company: company,
        user: user,
        location: project.deal&.location,
        to: recipient_phone,
        body: message,
        category: 'project_notification',
        communicable: project
      )
    rescue => e
      Rails.logger.error("[ProjectNotification] SMS failed: #{e.message}")
    end

    def find_sending_user(project)
      project.deal&.user || project.company.users.where(is_active: true, role: 'admin').first
    end

    def recipient_display_name(pref)
      case pref.recipient_type
      when 'User'
        u = User.find_by(id: pref.recipient_id)
        u ? u.first_name.to_s : 'there'
      when 'Contact'
        c = Contact.find_by(id: pref.recipient_id)
        c ? c.first_name.to_s : 'there'
      else
        'there'
      end
    end

    def build_subject(project, phase, event, task = nil)
      home_name = project.name || 'Your Home'

      case event
      when 'phase_started'
        "#{home_name} — #{phase.name} has started"
      when 'phase_completed'
        "#{home_name} — #{phase.name} is complete!"
      when 'task_completed'
        "#{home_name} — #{task&.title || 'Task'} completed"
      when 'task_assigned'
        "#{home_name} — New task assigned: #{task&.title}"
      when 'milestone_reached'
        "#{home_name} — Milestone reached: #{phase.name}"
      when 'inspection_passed'
        "#{home_name} — Inspection passed: #{phase.name}"
      when 'inspection_failed'
        "#{home_name} — Inspection needs attention: #{phase.name}"
      when 'payment_due'
        "#{home_name} — Payment milestone reached"
      else
        "#{home_name} — Project Update"
      end
    end

    def build_body(project, phase, event, recipient_name, task = nil)
      completion = project.progress_percent || 0

      <<~HTML
        <p>Hi #{recipient_name},</p>

        #{event_specific_message(event, phase, task)}

        <p><strong>Overall Progress:</strong> #{completion}% complete</p>

        #{public_link_section(project)}

        <p>Thank you,<br/>Your Home Setup Team</p>
      HTML
    end

    def event_specific_message(event, phase, task)
      case event
      when 'phase_started'
        "<p>Great news! The <strong>#{phase.name}</strong> phase of your home project has begun.</p>"
      when 'phase_completed'
        "<p>The <strong>#{phase.name}</strong> phase of your home project is now complete!</p>"
      when 'task_completed'
        "<p>The task <strong>#{task&.title}</strong> in the #{phase.name} phase has been completed.</p>"
      when 'task_assigned'
        "<p>You have been assigned a new task: <strong>#{task&.title}</strong> in the #{phase.name} phase.</p>"
      else
        "<p>There's an update on the #{phase.name} phase of your home project.</p>"
      end
    end

    def public_link_section(project)
      if project.client_access_token.present?
        url = "#{Rails.application.credentials.dig(:app, :frontend_url)}/p/#{project.client_access_token}"
        "<p><a href='#{url}'>View your project progress online</a></p>"
      else
        ""
      end
    end

    def build_sms_message(project, phase, event)
      home_name = project.name || 'Your Home'

      case event
      when 'phase_started'
        "#{home_name}: #{phase.name} has started! #{completion_text(project)}"
      when 'phase_completed'
        "#{home_name}: #{phase.name} is complete! #{completion_text(project)}"
      else
        "#{home_name}: Update on #{phase.name}. #{completion_text(project)}"
      end
    end

    def completion_text(project)
      "Overall: #{project.progress_percent || 0}% done."
    end
  end
end

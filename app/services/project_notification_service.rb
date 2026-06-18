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
    email_sent_via_prefs = false

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
        email_sent_via_prefs = true
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

    # ── Auto-fallback: if no notification_preferences row sent an email,
    # automatically email the project's client when the phase is visible_to_client
    # and we can resolve a client email. This makes "phase complete → client gets
    # notified" work out of the box without requiring per-project preference setup.
    unless email_sent_via_prefs
      send_phase_change_to_client_fallback(project, phase, event)
    end
  end

  # ── Auto-fallback client notification when no notification_preferences exist.
  # Sends a clean HTML email to the project's customer when the phase is
  # visible_to_client. Routes through the company/platform email provider
  # (AWS SES) — no dealer OAuth, no per-project setup required.
  def self.send_phase_change_to_client_fallback(project, phase, event)
    return unless phase.visible_to_client

    client_email = resolve_client_email(project)
    unless client_email.present?
      Rails.logger.info("[ProjectNotificationService] phase fallback: no client email for project #{project.id}")
      return
    end

    company = project.company
    home_name = project.name || 'Your Home'
    client_name = resolve_client_name(project) || 'there'

    # Recalculate progress live from a fresh DB query rather than reading the
    # stored project.progress_percent column. The stored value can be stale —
    # for example when a dealer manually closes a phase, nothing updates the
    # column before this email fires, so it would report the percentage from
    # BEFORE the just-closed phase. The fresh query inside the same transaction
    # already sees the updated phase.status, so the count is correct.
    total_phases     = ProjectPhase.where(project_id: project.id).count
    completed_phases = ProjectPhase.where(project_id: project.id, status: 'completed').count
    completion = total_phases > 0 ? ((completed_phases.to_f / total_phases) * 100).round : 0

    # Persist the recalculated value so other consumers (project show, dashboard,
    # progress tracker) see the same number. update_columns skips callbacks/timestamps
    # to avoid re-firing the after_save chain.
    project.update_columns(progress_percent: completion) if project.progress_percent != completion

    subject = case event
              when 'phase_started'   then "#{home_name} — #{phase.name} has started"
              when 'phase_completed' then "#{home_name} — #{phase.name} is complete!"
              else                        "#{home_name} — Project Update"
              end

    headline = case event
               when 'phase_started'
                 "<p>Great news! The <strong>#{phase.name}</strong> phase of your project has begun.</p>"
               when 'phase_completed'
                 "<p>The <strong>#{phase.name}</strong> phase of your project is now complete!</p>"
               else
                 "<p>There's an update on the <strong>#{phase.name}</strong> phase of your project.</p>"
               end

    portal_link = if project.client_access_token.present?
      url = "#{frontend_base_url}/p/#{project.client_access_token}"
      <<~CTA
        <div style="text-align: center; margin: 28px 0;">
          <a href="#{url}"
             style="display: inline-block; background-color: #2563eb; color: #ffffff !important;
                    text-decoration: none; font-weight: 600; padding: 12px 28px; border-radius: 6px;
                    font-size: 14px;">
            View Project Progress
          </a>
        </div>
        <p style="font-size: 12px; color: #888; text-align: center; margin-top: 8px;">
          Or copy and paste this URL into your browser:<br>
          <a href="#{url}" style="color: #2563eb;">#{url}</a>
        </p>
      CTA
    else
      ''
    end

    body = <<~HTML
      <p>Hi #{client_name},</p>
      #{headline}
      <p><strong>Overall Progress:</strong> #{completion}% complete</p>
      #{portal_link}
      <p>Thank you,<br>#{company.name}</p>
    HTML

    # wrap_html will skip its own CTA because the body already contains the
    # client portal link block above. We pass audience: :client so the wrapper
    # doesn't append a contractor/dealer login button.
    CommunicationService.send_email(
      company: company,
      to: client_email,
      subject: subject,
      body: wrap_html_minimal(body, subject),
      category: 'project_notification',
      communicable: project
    )
    Rails.logger.info("[ProjectNotificationService] phase fallback email sent to client #{client_email} for project #{project.id}")
  rescue => e
    Rails.logger.error("[ProjectNotificationService] phase fallback error: #{e.class}: #{e.message}")
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

  # ── Dispatch pending contractor notifications inline.
  # Called by both ContractorAssignmentNotifierJob (async/debounced) and the
  # flush endpoint (sync/immediate). Always stamps notified_at on the rows it
  # processed, even if the email fails — we don't want infinite retries.
  # @return [Integer] number of assignments processed
  def self.dispatch_pending_assignments_for_contractor(contractor_id)
    contractor = ::Contractor.find_by(id: contractor_id, is_deleted: [false, nil])
    unless contractor
      Rails.logger.info("[ProjectNotificationService] dispatch: contractor #{contractor_id} not found")
      return 0
    end

    pending = ContractorAssignment.where(
      contractor_id: contractor_id,
      notified_at: nil,
      notification_paused_at: nil,
      notification_skipped_at: nil
    ).includes(:company, :assignable).order(:created_at).to_a

    if pending.empty?
      Rails.logger.info("[ProjectNotificationService] dispatch: no pending assignments for contractor #{contractor_id}")
      return 0
    end

    Rails.logger.info("[ProjectNotificationService] dispatch: sending #{pending.size} assignment(s) to contractor #{contractor_id}")

    pending.group_by(&:company_id).each do |company_id, assignments|
      begin
        notify_contractor_assigned_batch(contractor, assignments)
      rescue => e
        Rails.logger.error("[ProjectNotificationService] dispatch: batch error for company #{company_id}: #{e.class}: #{e.message}")
      end
    end

    # Stamp notified_at on ALL processed rows (including ones whose email failed)
    # so the UI clears and we don't retry forever. Failed emails will appear in
    # the Communications log as status=failed and can be manually resent.
    ContractorAssignment.where(id: pending.map(&:id)).update_all(notified_at: Time.current)
    pending.size
  end

  # ── Dispatch pending dealer review notifications inline for a project.
  # @return [Integer] number of reviews processed
  def self.dispatch_pending_reviews_for_project(project_id)
    project = Project.find_by(id: project_id)
    unless project
      Rails.logger.info("[ProjectNotificationService] dispatch: project #{project_id} not found")
      return 0
    end

    pending = ContractorAssignment.joins(
      "INNER JOIN project_phase_tasks ON project_phase_tasks.id = contractor_assignments.assignable_id"
    ).joins(
      "INNER JOIN project_phases ON project_phases.id = project_phase_tasks.project_phase_id"
    ).where(
      contractor_assignments: { assignable_type: 'ProjectPhaseTask', review_status: 'pending_review', review_notified_at: nil },
      project_phases: { project_id: project_id }
    ).includes(:contractor, :assignable).to_a

    if pending.empty?
      Rails.logger.info("[ProjectNotificationService] dispatch: no pending reviews for project #{project_id}")
      return 0
    end

    Rails.logger.info("[ProjectNotificationService] dispatch: sending #{pending.size} review(s) for project #{project_id}")

    begin
      notify_review_submitted_batch(project, pending)
    rescue => e
      Rails.logger.error("[ProjectNotificationService] dispatch: review batch error for project #{project_id}: #{e.class}: #{e.message}")
    end

    ContractorAssignment.where(id: pending.map(&:id)).update_all(review_notified_at: Time.current)
    pending.size
  end

  # ── BATCHED: Contractor assigned email (called by ContractorAssignmentNotifierJob)
  # Sends ONE email listing all pending assignments for a contractor within a company.
  def self.notify_contractor_assigned_batch(contractor, assignments)
    return if assignments.blank?
    return unless contractor&.email.present?

    company = assignments.first.company
    count = assignments.size

    rows = assignments.map do |a|
      task_name = resolve_task_name(a)
      project = resolve_project(a)
      location = project ? " — #{project.name}" : ''
      note = a.notes.present? ? "<div style=\"color:#666;font-size:13px;margin-top:2px;\">#{a.notes}</div>" : ''
      "<li style=\"margin-bottom:10px;\"><strong>#{task_name}</strong>#{location}#{note}</li>"
    end.join

    subject = if count == 1
      "New Assignment: #{resolve_task_name(assignments.first)}"
    else
      "#{count} new assignments from #{company.name}"
    end

    body = <<~HTML
      <p>Hello #{contractor.contact_name.presence || contractor.name},</p>
      <p>You have #{count == 1 ? 'been assigned a new task' : "#{count} new assignments"}:</p>
      <ul style="padding-left: 20px; margin: 14px 0;">
        #{rows}
      </ul>
      <p>Please log in to the Contractor Portal to accept #{count == 1 ? 'this assignment' : 'these assignments'} and get started.</p>
      <p>Thank you,<br>#{company.name}</p>
    HTML

    # Use the first assignment as the `communicable` for threading
    send_contractor_review_email(contractor, company, subject, body, assignments.first)

    # Also text the contractor when they've opted in and have a number on file
    # (email + SMS). Opt-in is set on the Contractor Portal profile page (TCPA).
    # Isolated in its own rescue so an SMS/Twilio failure never blocks the email
    # that already sent, nor the notified_at stamping the caller does next.
    # SMS provider resolves Location -> Company -> Platform (most-specific wins).
    if contractor.sms_opt_in && contractor.phone.present?
      begin
        sms_body = if count == 1
          "New assignment from #{company.name}: #{resolve_task_name(assignments.first)}. " \
            "Log in to the Contractor Portal to accept."
        else
          "#{count} new assignments from #{company.name}. " \
            "Log in to the Contractor Portal to accept."
        end

        CommunicationService.send_sms(
          company: company,
          location: resolve_project(assignments.first)&.deal&.location,
          to: contractor.phone,
          body: sms_body,
          category: 'project_notification',
          communicable: assignments.first
        )
        Rails.logger.info("[ProjectNotificationService] Assignment SMS sent to contractor #{contractor.id}")
      rescue => e
        Rails.logger.error("[ProjectNotificationService] Contractor assignment SMS failed: #{e.message}")
      end
    end
  rescue => e
    Rails.logger.error("[ProjectNotificationService] Error notifying contractor batch: #{e.message}")
  end

  # ── Legacy single-item wrapper (preserved for any direct callers)
  def self.notify_contractor_assigned(assignment)
    notify_contractor_assigned_batch(assignment.contractor, [assignment])
  end

  # ── IMMEDIATE (bell + toast only, no email) when contractor submits for review
  # Email is batched via DealerReviewNotifierJob.
  def self.announce_review_submitted(assignment)
    company = assignment.company
    contractor = assignment.contractor
    task_name = resolve_task_name(assignment)
    contractor_name = contractor&.name || contractor&.contact_name || 'Contractor'

    primary_recipient = resolve_primary_recipient(assignment)
    admins = company.users.active.where(role: %w[admin company_admin platform_admin manager super_admin])
    recipients = ([primary_recipient] + admins.to_a).compact.uniq

    recipients.each do |user|
      create_bell_notification(
        recipient: user,
        company: company,
        type: :contractor_review_submitted,
        title: "Review Submitted: #{task_name}",
        message: "#{contractor_name} submitted work for review on #{task_name}",
        notifiable: assignment,
        actor_type: 'Contractor',
        actor_id: contractor&.id
      )

      broadcast_review_toast(user, {
        type: 'contractor_review',
        title: 'Review Submitted',
        description: "#{contractor_name} submitted \"#{task_name}\" for review",
        entityType: 'contractor_review',
        entityId: assignment.id,
        link: '/projects/reviews',
        linkText: 'Review Now'
      })
    end
  rescue => e
    Rails.logger.error("[ProjectNotificationService] Error announcing review: #{e.message}")
  end

  # ── BATCHED: Dealer review-submitted email (called by DealerReviewNotifierJob)
  # Sends ONE email listing all pending reviews on a project to the project owner.
  def self.notify_review_submitted_batch(project, assignments)
    return if assignments.blank?

    company = project.company
    # Use the first assignment to resolve the recipient (they should all resolve
    # to the same person since they're on the same project)
    primary_recipient = resolve_primary_recipient(assignments.first)

    unless primary_recipient&.email.present?
      Rails.logger.warn("[ProjectNotificationService] No recipient found for project #{project.id} batched review email")
      return
    end

    count = assignments.size
    rows = assignments.map do |a|
      task_name = resolve_task_name(a)
      contractor_name = a.contractor&.name || a.contractor&.contact_name || 'Contractor'
      summary = a.completion_summary.present? ? "<div style=\"color:#666;font-size:13px;margin-top:2px;\">#{a.completion_summary.to_s.truncate(200)}</div>" : ''
      photo_count = a.completion_photos.is_a?(Array) ? a.completion_photos.length : 0
      photos = photo_count > 0 ? "<div style=\"color:#888;font-size:12px;margin-top:2px;\">#{photo_count} photo(s) attached</div>" : ''
      "<li style=\"margin-bottom:12px;\"><strong>#{task_name}</strong> — #{contractor_name}#{summary}#{photos}</li>"
    end.join

    subject = if count == 1
      a = assignments.first
      contractor_name = a.contractor&.name || 'Contractor'
      "Review Submitted: #{resolve_task_name(a)} — #{contractor_name}"
    else
      "#{count} reviews pending on #{project.name}"
    end

    body = <<~HTML
      <p>Hello #{primary_recipient.full_name},</p>
      <p>#{count == 1 ? 'A contractor has' : "#{count} contractor submissions have"} submitted work for your review on <strong>#{project.name}</strong>:</p>
      <ul style="padding-left: 20px; margin: 14px 0;">
        #{rows}
      </ul>
      <p>Please log in to review and approve, request revisions, or reject.</p>
      <p>Thank you,<br>#{company.name}</p>
    HTML

    send_dealer_review_email(primary_recipient, company, subject, body, assignments.first)
  rescue => e
    Rails.logger.error("[ProjectNotificationService] Error notifying review batch: #{e.message}")
  end

  # ── Legacy single-item wrapper (preserved for any direct callers)
  def self.notify_review_submitted(assignment)
    announce_review_submitted(assignment)
    project = resolve_project(assignment)
    notify_review_submitted_batch(project, [assignment]) if project
  end

  # ── Dealer approves review → notify contractor ────────────────────
  def self.notify_review_approved(assignment, reviewer)
    contractor = assignment.contractor
    return unless contractor&.email.present?

    company = assignment.company
    task_name = resolve_task_name(assignment)

    subject = "Work Approved: #{task_name}"
    body = <<~HTML
      <p>Hello #{contractor.contact_name.presence || contractor.name},</p>
      <p>Great news! Your work on <strong>#{task_name}</strong> has been approved by #{reviewer&.full_name}.</p>
      #{assignment.review_notes.present? ? "<p><em>Notes:</em> #{assignment.review_notes}</p>" : ''}
      <p>Thank you for your excellent work!</p>
      <p>#{company.name}</p>
    HTML

    send_contractor_review_email(contractor, company, subject, body, assignment)
  rescue => e
    Rails.logger.error("[ProjectNotificationService] Error notifying review approved: #{e.message}")
  end

  # ── Dealer requests revision → notify contractor ──────────────────
  def self.notify_revision_requested(assignment, reviewer)
    contractor = assignment.contractor
    return unless contractor&.email.present?

    company = assignment.company
    task_name = resolve_task_name(assignment)

    subject = "Revision Requested: #{task_name}"
    body = <<~HTML
      <p>Hello #{contractor.contact_name.presence || contractor.name},</p>
      <p>Your submission for <strong>#{task_name}</strong> needs revision. #{reviewer&.full_name} has requested the following changes:</p>
      <blockquote style="border-left: 3px solid #f59e0b; padding-left: 12px; margin: 12px 0; color: #92400e;">
        #{assignment.revision_notes}
      </blockquote>
      <p>Please log in to the Contractor Portal, make the requested changes, and resubmit for review.</p>
      <p>Thank you,<br>#{company.name}</p>
    HTML

    send_contractor_review_email(contractor, company, subject, body, assignment)
  rescue => e
    Rails.logger.error("[ProjectNotificationService] Error notifying revision requested: #{e.message}")
  end

  # ── Dealer rejects review → notify contractor ─────────────────────
  def self.notify_review_rejected(assignment, reviewer)
    contractor = assignment.contractor
    return unless contractor&.email.present?

    company = assignment.company
    task_name = resolve_task_name(assignment)

    subject = "Work Rejected: #{task_name}"
    body = <<~HTML
      <p>Hello #{contractor.contact_name.presence || contractor.name},</p>
      <p>Your submission for <strong>#{task_name}</strong> has been rejected by #{reviewer&.full_name}.</p>
      #{assignment.review_notes.present? ? "<p><em>Reason:</em> #{assignment.review_notes}</p>" : ''}
      <p>If you have questions, please contact the dealer directly.</p>
      <p>#{company.name}</p>
    HTML

    send_contractor_review_email(contractor, company, subject, body, assignment)
  rescue => e
    Rails.logger.error("[ProjectNotificationService] Error notifying review rejected: #{e.message}")
  end

  # ── CUSTOMER APPROVAL FLOW (only when company setting require_client_approval is on)
  #
  # Contractor submitted work AND customer approval is required → email the customer
  # asking them to review/approve on the public progress page or logged-in portal.
  def self.notify_client_review_requested(assignment)
    project = resolve_project(assignment)
    return unless project

    client_email = resolve_client_email(project)
    unless client_email.present?
      Rails.logger.info("[ProjectNotificationService] client review requested: no client email for project #{project.id}")
      return
    end

    company = project.company
    task_name = resolve_task_name(assignment)
    client_name = resolve_client_name(project) || 'there'
    summary = assignment.completion_summary.present? ? "<p><em>What was done:</em> #{assignment.completion_summary.to_s.truncate(300)}</p>" : ''

    subject = "#{project.name} — Please review completed work: #{task_name}"

    portal_link = if project.client_access_token.present?
      url = "#{frontend_base_url}/p/#{project.client_access_token}"
      <<~CTA
        <div style="text-align: center; margin: 28px 0;">
          <a href="#{url}"
             style="display: inline-block; background-color: #2563eb; color: #ffffff !important;
                    text-decoration: none; font-weight: 600; padding: 12px 28px; border-radius: 6px;
                    font-size: 14px;">
            Review the Work
          </a>
        </div>
        <p style="font-size: 12px; color: #888; text-align: center; margin-top: 8px;">
          Or copy and paste this URL into your browser:<br>
          <a href="#{url}" style="color: #2563eb;">#{url}</a>
        </p>
      CTA
    else
      ''
    end

    body = <<~HTML
      <p>Hi #{client_name},</p>
      <p>A contractor has completed work on <strong>#{task_name}</strong> for your project, and it's ready for your review.</p>
      #{summary}
      <p>Since you're on-site, please take a look and let us know whether the work is approved or needs attention.</p>
      #{portal_link}
      <p>Thank you,<br>#{company.name}</p>
    HTML

    CommunicationService.send_email(
      company: company,
      to: client_email,
      subject: subject,
      body: wrap_html_minimal(body, subject),
      category: 'project_notification',
      communicable: project
    )
    Rails.logger.info("[ProjectNotificationService] client review request email sent to #{client_email} for assignment #{assignment.id}")
  rescue => e
    Rails.logger.error("[ProjectNotificationService] Error notifying client review requested: #{e.message}")
  end

  # Customer approved the work (gate 1) → bell + toast + email to dealer prompting the
  # final confirm that actually closes the task.
  def self.notify_client_approved(assignment)
    company = assignment.company
    project = resolve_project(assignment)
    task_name = resolve_task_name(assignment)
    on_behalf = assignment.acted_on_behalf_by_id.present?
    actor_label = on_behalf ? 'on the customer\'s behalf' : 'by the customer'

    primary_recipient = resolve_primary_recipient(assignment)
    admins = company.users.active.where(role: %w[admin company_admin platform_admin manager super_admin])
    recipients = ([primary_recipient] + admins.to_a).compact.uniq

    recipients.each do |user|
      create_bell_notification(
        recipient: user,
        company: company,
        type: :contractor_review_submitted,
        title: "Customer Approved: #{task_name}",
        message: "#{task_name} was approved #{actor_label} — ready for your final confirmation.",
        notifiable: assignment
      )

      broadcast_review_toast(user, {
        type: 'contractor_review',
        title: 'Customer Approved',
        description: "#{task_name} approved #{actor_label} — confirm to close",
        entityType: 'contractor_review',
        entityId: assignment.id,
        link: '/projects/reviews',
        linkText: 'Confirm Now'
      })
    end

    if primary_recipient&.email.present?
      notes = assignment.client_review_notes.present? ? "<p><em>Customer notes:</em> #{assignment.client_review_notes}</p>" : ''
      subject = "Customer approved #{task_name} — confirm to close"
      body = <<~HTML
        <p>Hello #{primary_recipient.full_name},</p>
        <p>The customer has approved the completed work on <strong>#{task_name}</strong>#{on_behalf ? ' (recorded on their behalf)' : ''} for <strong>#{project&.name}</strong>.</p>
        #{notes}
        <p>Please log in to give the final confirmation, which will close out the task.</p>
        <p>Thank you,<br>#{company.name}</p>
      HTML
      send_dealer_review_email(primary_recipient, company, subject, body, assignment)
    end
  rescue => e
    Rails.logger.error("[ProjectNotificationService] Error notifying client approved: #{e.message}")
  end

  # Customer rejected or requested a revision (gate 1) → notify the contractor to redo
  # the work AND notify the dealer that the customer pushed back.
  def self.notify_client_rejected(assignment)
    company = assignment.company
    contractor = assignment.contractor
    project = resolve_project(assignment)
    task_name = resolve_task_name(assignment)
    rejected = assignment.client_review_status == ContractorAssignment::CLIENT_REVIEW_REJECTED
    on_behalf = assignment.acted_on_behalf_by_id.present?

    # 1) Contractor: redo the work
    if contractor&.email.present?
      subject = "#{rejected ? 'Work Rejected' : 'Revision Requested'} by Customer: #{task_name}"
      body = <<~HTML
        <p>Hello #{contractor.contact_name.presence || contractor.name},</p>
        <p>The customer has #{rejected ? 'rejected' : 'requested a revision on'} your work for <strong>#{task_name}</strong>.</p>
        #{assignment.client_review_notes.present? ? "<blockquote style=\"border-left: 3px solid #f59e0b; padding-left: 12px; margin: 12px 0; color: #92400e;\">#{assignment.client_review_notes}</blockquote>" : ''}
        <p>Please log in to the Contractor Portal, make the requested changes, and resubmit for review.</p>
        <p>Thank you,<br>#{company.name}</p>
      HTML
      send_contractor_review_email(contractor, company, subject, body, assignment)
    end

    # 2) Dealer: bell + toast for visibility
    primary_recipient = resolve_primary_recipient(assignment)
    admins = company.users.active.where(role: %w[admin company_admin platform_admin manager super_admin])
    recipients = ([primary_recipient] + admins.to_a).compact.uniq

    recipients.each do |user|
      create_bell_notification(
        recipient: user,
        company: company,
        type: :contractor_review_submitted,
        title: "Customer #{rejected ? 'Rejected' : 'Requested Revision'}: #{task_name}",
        message: "The customer #{rejected ? 'rejected' : 'requested a revision on'} #{task_name}#{on_behalf ? ' (recorded on their behalf)' : ''}. The contractor has been asked to redo it.",
        notifiable: assignment
      )

      broadcast_review_toast(user, {
        type: 'contractor_review',
        title: rejected ? 'Customer Rejected Work' : 'Customer Requested Revision',
        description: "#{task_name} sent back to the contractor",
        entityType: 'contractor_review',
        entityId: assignment.id,
        link: '/projects/reviews',
        linkText: 'View'
      })
    end
  rescue => e
    Rails.logger.error("[ProjectNotificationService] Error notifying client rejected: #{e.message}")
  end

  # ── Work log added → bell notification for dealer users ──────────
  def self.notify_work_log_added(work_log, assignment)
    return unless work_log.author_type == 'contractor'

    company = assignment.company
    contractor = assignment.contractor
    task_name = resolve_task_name(assignment)
    contractor_name = contractor&.name || contractor&.contact_name || 'Contractor'

    has_photos = work_log.attachments.is_a?(Array) && work_log.attachments.any?
    return unless work_log.note.present? || has_photos

    primary_recipient = resolve_primary_recipient(assignment)
    admins = company.users.active.where(role: %w[admin company_admin platform_admin manager super_admin])
    recipients = ([primary_recipient] + admins.to_a).compact.uniq

    recipients.each do |user|
      create_bell_notification(
        recipient: user,
        company: company,
        type: :contractor_work_log_added,
        title: "Work Log: #{task_name}",
        message: "#{contractor_name} added a work log entry#{has_photos ? ' with photos' : ''}",
        notifiable: assignment
      )
    end
  rescue => e
    Rails.logger.error("[ProjectNotificationService] Error notifying work log: #{e.message}")
  end

  class << self
    private

    # Waterfall: project.owner → project.deal.owner → project.deal.account.owner → first company admin
    def resolve_primary_recipient(assignment)
      project = resolve_project(assignment)

      if project
        return project.owner if project.owner.present?

        deal = project.deal rescue nil
        if deal
          return deal.owner if deal.respond_to?(:owner) && deal.owner.present?

          account = deal.account rescue nil
          if account
            return account.owner if account.respond_to?(:owner) && account.owner.present?
          end
        end
      end

      # Final fallback: first company admin
      assignment.company.users.active.where(role: %w[admin company_admin platform_admin manager super_admin]).first
    rescue => e
      Rails.logger.warn("[ProjectNotificationService] resolve_primary_recipient error: #{e.message}")
      assignment.company.users.active.where(role: %w[admin company_admin platform_admin manager super_admin]).first
    end

    def resolve_project(assignment)
      return nil unless assignment.assignable_type == 'ProjectPhaseTask'
      assignment.assignable&.project_phase&.project
    rescue
      nil
    end

    def resolve_task_name(assignment)
      assignable = assignment.assignable
      return "Assignment ##{assignment.id}" unless assignable

      case assignment.assignable_type
      when 'ProjectPhaseTask'
        assignable.name || "Task ##{assignable.id}"
      when 'ServiceTicket'
        assignable.try(:title) || assignable.try(:ticket_number) || "##{assignable.id}"
      else
        assignable.respond_to?(:name) ? assignable.name : "Assignment ##{assignment.id}"
      end
    end

    def send_contractor_review_email(contractor, company, subject, body, assignment)
      CommunicationService.send_email(
        company: company,
        to: contractor.email,
        subject: subject,
        body: wrap_html(body, subject, audience: :contractor),
        category: 'project_notification',
        communicable: assignment
      )
      Rails.logger.info("[ProjectNotificationService] Email sent to contractor #{contractor.email}")
    end

    def send_dealer_review_email(user, company, subject, body, assignment)
      # Intentionally do NOT pass `user:` — that would route through the user's
      # personal OAuth (Gmail/Outlook) connection, which can be expired or revoked.
      # System-generated notifications should use the company/platform email provider
      # (AWS SES via the Location → Company → Platform waterfall).
      CommunicationService.send_email(
        company: company,
        to: user.email,
        subject: subject,
        body: wrap_html(body, subject, audience: :dealer),
        category: 'project_notification',
        communicable: assignment
      )
      Rails.logger.info("[ProjectNotificationService] Email sent to dealer #{user.email} (via company/platform provider)")
    end

    # Wrap the HTML body fragment in a minimal <html><body> so the
    # CommunicationMailer detects it as HTML (it checks for '<html' or '<body').
    # Appends an audience-appropriate login CTA (contractor portal vs dealer app).
    def wrap_html(body, subject = nil, audience: :contractor)
      return body if body.to_s.include?('<html') || body.to_s.include?('<body')

      login_url, button_text = if audience == :dealer
        [dealer_login_url, 'Login to Renter Insight']
      else
        [contractor_portal_url, 'Login to Contractor Portal']
      end

      cta = <<~CTA
        <div style="text-align: center; margin: 28px 0;">
          <a href="#{login_url}"
             style="display: inline-block; background-color: #2563eb; color: #ffffff !important;
                    text-decoration: none; font-weight: 600; padding: 12px 28px; border-radius: 6px;
                    font-size: 14px;">
            #{button_text}
          </a>
        </div>
        <p style="font-size: 12px; color: #888; text-align: center; margin-top: 8px;">
          Or copy and paste this URL into your browser:<br>
          <a href="#{login_url}" style="color: #2563eb;">#{login_url}</a>
        </p>
      CTA

      <<~HTML
        <!DOCTYPE html>
        <html>
          <head>
            <meta charset="UTF-8">
            <title>#{subject}</title>
          </head>
          <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif; color: #333; line-height: 1.5; max-width: 600px; margin: 0 auto; padding: 20px;">
            #{body}
            #{cta}
          </body>
        </html>
      HTML
    end

    def contractor_portal_url
      "#{frontend_base_url}/contractor/login"
    end

    # Client email waterfall: project.customer_email → deal.contact.email → deal.account.email
    def resolve_client_email(project)
      return project.customer_email if project.customer_email.present?

      deal = project.deal rescue nil
      if deal
        contact = deal.try(:contact)
        return contact.email if contact&.email.present?

        account = deal.try(:account)
        return account.email if account&.email.present?
      end

      nil
    end

    # Client name waterfall: project.customer_name → deal.contact name → deal.account name
    def resolve_client_name(project)
      return project.customer_name if project.customer_name.present?

      deal = project.deal rescue nil
      if deal
        contact = deal.try(:contact)
        if contact
          full = [contact.try(:first_name), contact.try(:last_name)].compact.reject(&:blank?).join(' ')
          return full if full.present?
          return contact.try(:name) if contact.respond_to?(:name)
        end

        account = deal.try(:account)
        return account.try(:name) if account&.try(:name).present?
      end

      nil
    end

    # Minimal HTML wrapper without an audience-specific CTA button.
    # Used for client emails where the body itself already contains the
    # appropriate portal link.
    def wrap_html_minimal(body, subject = nil)
      return body if body.to_s.include?('<html') || body.to_s.include?('<body')

      <<~HTML
        <!DOCTYPE html>
        <html>
          <head>
            <meta charset="UTF-8">
            <title>#{subject}</title>
          </head>
          <body style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Arial, sans-serif; color: #333; line-height: 1.5; max-width: 600px; margin: 0 auto; padding: 20px;">
            #{body}
          </body>
        </html>
      HTML
    end

    def dealer_login_url
      "#{frontend_base_url}/login"
    end

    def frontend_base_url
      base = ENV['FRONTEND_URL'].presence ||
             Rails.application.credentials.dig(:app, :frontend_url).presence ||
             'https://app.renterinsight.com'
      base.chomp('/')
    end

    def create_bell_notification(recipient:, company:, type:, title:, message:, notifiable: nil, actor_type: nil, actor_id: nil)
      type_config = Notification::TYPES[type] || { category: 'service', priority: 'normal' }

      Notification.create!(
        recipient: recipient,
        company: company,
        notification_type: type.to_s,
        category: type_config[:category],
        priority: type_config[:priority],
        title: title,
        message: message,
        notifiable: notifiable,
        actor_type: actor_type,
        actor_id: actor_id,
        read: false
      )
    rescue => e
      Rails.logger.error("[ProjectNotificationService] Error creating bell notification: #{e.message}")
    end

    def broadcast_review_toast(user, data)
      ActionCable.server.broadcast(
        "user_notifications_#{user.id}",
        {
          type: 'activity_notification',
          activity: {
            id: SecureRandom.hex(8),
            type: data[:type],
            subject: data[:title],
            priority: 'high',
            entityName: data[:description],
            entityType: data[:entityType],
            entityId: data[:entityId]
          },
          settings: { popup: true, sound: false },
          link: data[:link],
          linkText: data[:linkText]
        }
      )
      Rails.logger.info("[ProjectNotificationService] ActionCable toast broadcast to user #{user.id}")
    rescue => e
      Rails.logger.error("[ProjectNotificationService] Error broadcasting toast: #{e.message}")
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

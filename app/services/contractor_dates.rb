# frozen_string_literal: true

# A contractor's start date and duration landing on the project (E107).
#
# Duration is in work days, Monday to Friday: 6 work days starting Tuesday
# Dec 1, 2026 end Tuesday Dec 8. Decided with Tom 2026-11-19.
#
# When the contractor accepts a task (or the whole phase they run), their
# dates go straight onto it if it has no dates yet. If it already has dates,
# the dealer set them, so the contractor's dates wait for the dealer to
# confirm or turn down (Review Updates, and on the project).
class ContractorDates
  class Error < StandardError; end

  # The last work day of a job that starts on start and takes work_days.
  # A start on a weekend counts from the Monday after.
  def self.end_date(start, work_days)
    return nil if start.nil? || work_days.to_i < 1

    day = start
    day += 1 while weekend?(day)
    left = work_days.to_i - 1
    while left.positive?
      day += 1
      left -= 1 unless weekend?(day)
    end
    day
  end

  def self.weekend?(day) = day.saturday? || day.sunday?

  def initialize(assignment)
    @assignment = assignment
    @task = assignment.assignable
  end

  # The task's phase, when this contractor runs the whole phase.
  def phase_owned
    phase = @task.try(:project_phase)
    phase if phase && phase.assigned_vendor_id.present? && phase.assigned_vendor_id == @assignment.vendor_id
  end

  # Records what the contractor proposed and applies it when nothing is
  # there yet. Returns :applied or :pending.
  def propose!(start:, work_days:, notes: nil, for_phase: false)
    raise Error, 'Pick a start date' if start.blank?
    raise Error, 'Enter how many work days it takes' if work_days.to_i < 1
    raise Error, 'That is more than a year of work days' if work_days.to_i > 260

    start = Date.parse(start.to_s)
    finish = self.class.end_date(start, work_days)
    target = for_phase ? phase_owned : @task
    raise Error, 'You do not run that whole phase' if for_phase && target.nil?

    has_dates = target.estimated_start_date.present? || target.estimated_completion_date.present?
    same = target.estimated_start_date == start && target.estimated_completion_date == finish
    status = has_dates && !same ? 'pending' : 'applied'

    ActiveRecord::Base.transaction do
      @assignment.update!(proposed_start_date: start, proposed_work_days: work_days.to_i, proposed_end_date: finish,
                          proposed_for: for_phase ? 'phase' : 'task', dates_status: status,
                          accept_notes: notes.presence, dates_decided_at: nil, dates_decided_by_id: nil)
      apply!(target) if status == 'applied'
    end
    status == 'applied' ? notify_applied(target) : open_review(target)
    status.to_sym
  end

  # Dealer side.
  def confirm!(user)
    raise Error, 'There are no dates waiting on this' unless @assignment.dates_status == 'pending'

    target = proposed_target
    ActiveRecord::Base.transaction do
      apply!(target)
      @assignment.update!(dates_status: 'confirmed', dates_decided_at: Time.current, dates_decided_by_id: user&.id)
    end
    ProjectNotices.close!(subject: @assignment, kinds: 'contractor_dates', resolution: 'confirmed', by: user)
    tell_contractor(true)
  end

  def decline!(user)
    raise Error, 'There are no dates waiting on this' unless @assignment.dates_status == 'pending'

    @assignment.update!(dates_status: 'declined', dates_decided_at: Time.current, dates_decided_by_id: user&.id)
    ProjectNotices.close!(subject: @assignment, kinds: 'contractor_dates', resolution: 'declined', by: user)
    tell_contractor(false)
  end

  def proposed_target
    @assignment.proposed_for == 'phase' ? (@task.try(:project_phase) || @task) : @task
  end

  def label
    target = proposed_target
    target.is_a?(ProjectPhase) ? "#{target.name} (whole phase)" : target.name
  end

  private

  def apply!(target)
    target.update!(estimated_start_date: @assignment.proposed_start_date,
                   estimated_completion_date: @assignment.proposed_end_date)
  end

  def project = @task.try(:project_phase)&.project

  def fmt(date) = date&.strftime('%b %-d')

  def span
    "#{fmt(@assignment.proposed_start_date)} to #{fmt(@assignment.proposed_end_date)} " \
      "(#{@assignment.proposed_work_days} work #{'day'.pluralize(@assignment.proposed_work_days)})"
  end

  def notes_line
    @assignment.accept_notes.present? ? " Notes: #{@assignment.accept_notes.truncate(300)}" : ''
  end

  def owner_users
    proj = project
    users = [proj&.owner, @assignment.assigned_by].compact
    users.presence || @assignment.company.users.where(role: %w[company_admin admin]).limit(3).to_a
  end

  def open_review(target)
    proj = project
    old = "#{fmt(target.estimated_start_date) || 'no start'} to #{fmt(target.estimated_completion_date) || 'no end'}"
    title = "#{@assignment.contractor.name} proposes #{span} for #{label}"
    ProjectNotices.deliver(
      users: owner_users, type: 'project_contractor_dates', title: title,
      message: "Your dates are #{old}. Confirm to use theirs, or keep yours.#{notes_line}",
      notifiable: @assignment, company: @assignment.company,
      action_url: proj ? "/projects/#{proj.id}" : nil,
      item: { kind: 'contractor_dates', subject: @assignment, title: title,
              detail: "Now #{old}. Proposed #{span}.#{notes_line}", project: proj,
              phase: @task.try(:project_phase), from_name: @assignment.contractor.name,
              assigned_user: proj&.owner,
              metadata: { proposed_start: @assignment.proposed_start_date.to_s, proposed_end: @assignment.proposed_end_date.to_s,
                          work_days: @assignment.proposed_work_days, current_start: target.estimated_start_date.to_s,
                          current_end: target.estimated_completion_date.to_s, assignment_id: @assignment.id } }
    )
  end

  def notify_applied(_target)
    proj = project
    ProjectNotices.deliver(
      users: owner_users, type: 'project_contractor_dates',
      title: "#{@assignment.contractor.name} accepted #{label}: #{span}",
      message: "The dates are on the project.#{notes_line}",
      notifiable: @assignment, company: @assignment.company,
      action_url: proj ? "/projects/#{proj.id}" : nil
    )
  end

  # The contractor hears whether their dates were taken, on their vendor
  # record's consent, like every other portal notice.
  def tell_contractor(confirmed)
    ProjectNotificationService.try(:notify_contractor_dates_decided, @assignment, confirmed)
  rescue StandardError => e
    Rails.logger.error("[ContractorDates] tell contractor #{@assignment.id}: #{e.class}: #{e.message}")
  end
end

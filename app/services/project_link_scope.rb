# frozen_string_literal: true

# The dealer adds or changes a task on a phase a linked installer runs (E106).
#
# By default nothing crosses: the installer keeps the copy of the job they
# accepted, and the dealer's new task stays on the dealer's project. When the
# dealer sends it, the installer's copy gets the task (or the change), and a
# scope change waits for the installer to answer with a change order or "no
# charge". While it waits, that phase can't start on the installer's side
# (ProjectPhase#price_hold_message), like a change order waiting the other way.
class ProjectLinkScope
  class Error < StandardError; end

  TASK_FIELDS = %w[name estimated_days estimated_start_date estimated_completion_date].freeze

  # The live hand-off of a dealer phase, or nil.
  def self.map_for(dealer_phase)
    ProjectLinkPhase.joins(:project_link).includes(project_link: %i[installer_company dealer_company company_link])
                    .where(dealer_phase_id: dealer_phase.id, project_links: { status: 'accepted' })
                    .where.not(installer_phase_id: nil).first
  end

  def initialize(actor:)
    @actor = actor
  end

  # Dealer side: a task just added under a handed-off phase.
  def send_new_task!(task)
    map = map_for!(task.project_phase)
    copy = nil
    change = nil
    ActiveRecord::Base.transaction do
      copy = copy_task!(map, task)
      change = map.project_link.scope_changes.create!(
        dealer_phase_id: map.dealer_phase_id, dealer_task: task, installer_task: copy, kind: 'task_added',
        description: "New task: #{task.name}#{span(task)}", requested_by: @actor
      )
    end
    CompanyLinkNotifier.scope_changed(change)
    change
  end

  # Dealer side: a task changed (name or dates). before holds the old values.
  def send_task_change!(task, before)
    map = map_for!(task.project_phase)
    said = TASK_FIELDS.filter_map do |f|
      old = before[f]
      new = task.public_send(f)
      next if old.to_s == new.to_s

      "#{f.humanize.sub('Estimated ', '').downcase} #{show(old)} to #{show(new)}"
    end
    raise Error, 'Nothing to send: the name and dates are the same as before' if said.empty?

    change = nil
    ActiveRecord::Base.transaction do
      copy = ProjectPhaseTask.find_by(project_phase_id: map.installer_phase_id, linked_task_id: task.id) || copy_task!(map, task)
      copy.update!(name: task.name, estimated_days: task.estimated_days, estimated_start_date: task.estimated_start_date,
                   estimated_completion_date: task.estimated_completion_date)
      change = map.project_link.scope_changes.create!(
        dealer_phase_id: map.dealer_phase_id, dealer_task: task, installer_task: copy, kind: 'task_changed',
        description: "#{task.name}: #{said.join('; ')}", requested_by: @actor
      )
    end
    CompanyLinkNotifier.scope_changed(change)
    change
  end

  # Installer side: the change costs nothing more.
  def no_charge!(change, company)
    check_installer!(change, company)
    change.update!(status: 'no_charge', answered_by: @actor, answered_at: Time.current)
    CompanyLinkNotifier.scope_answered(change)
    change
  end

  # Installer side: answered with a change order (ProjectLinkService#request_change!).
  def answered_with_change_order!(change, link_change)
    change.update!(status: 'change_order', answered_by: @actor, answered_at: Time.current, link_change: link_change)
    CompanyLinkNotifier.scope_answered(change)
    change
  end

  private

  def map_for!(phase)
    self.class.map_for(phase) || raise(Error, "#{phase.name} isn't run by a linked installer")
  end

  def check_installer!(change, company)
    raise Error, 'Only the installer can answer this' unless change.project_link.installer_company_id == company.id
    raise Error, 'This was already answered' unless change.pending?
  end

  def copy_task!(map, task)
    iph = map.installer_phase
    iph.project_phase_tasks.create!(
      company_id: iph.company_id, linked_task_id: task.id, name: task.name, position: iph.project_phase_tasks.count,
      is_required: task.is_required, status: 'pending', estimated_days: task.estimated_days,
      estimated_start_date: task.estimated_start_date, estimated_completion_date: task.estimated_completion_date,
      visible_to_client: false
    )
  end

  def span(task)
    return '' unless task.estimated_start_date

    " (#{show(task.estimated_start_date)}#{task.estimated_completion_date ? " to #{show(task.estimated_completion_date)}" : ''})"
  end

  def show(value)
    case value
    when nil, '' then 'none'
    when Date then value.strftime('%b %-d')
    else value.to_s
    end
  end
end

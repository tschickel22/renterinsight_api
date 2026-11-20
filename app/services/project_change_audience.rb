# frozen_string_literal: true

# Who hears about a change on a project, said before it is saved (E106).
# Tom 2026-11-19: moving dates on a phase run by a linked installer notified
# them, and nothing on the screen said it would.
#
# It mirrors what the code really does:
#   - Dates on a phase handed to (or from) a linked company: that company gets
#     a bell, an email and a Review Updates item (ProjectLinkSync#tell_dates).
#     Moving a task's dates moves the later phases too, so the screen passes
#     every phase the change will move.
#   - A phase starting or finishing: the customer, by the project's
#     notification settings or the phase's own switches
#     (ProjectNotificationService.notify_phase_change). Installer side: the
#     dealer's project follows, and the customer hears under the dealer's name.
#   - Contractors on the work are not told about dates; say so, so nobody
#     assumes they were.
#   - A task added or changed on a handed-off phase stays here unless sent.
class ProjectChangeAudience
  Line = Struct.new(:text, :tone, keyword_init: true) # tone: tell | quiet | choice

  def initialize(project)
    @project = project
    @company = project.company
  end

  def dates(phase_ids)
    phases = @project.project_phases.where(id: phase_ids).order(:position).to_a
    return [quiet('No phases move.')] if phases.empty?

    lines = []
    by_company = Hash.new { |h, k| h[k] = [] }
    phases.each do |ph|
      other = other_company(ph)
      by_company[other.name] << ph.name if other
    end
    by_company.each do |name, names|
      lines << tell("This tells #{name} (bell, email and Review Updates), because they run #{names.to_sentence}.")
    end
    lines << quiet('The customer is not told about date changes.')
    contractors = contractor_names(phases)
    lines << quiet("#{contractors.to_sentence} #{contractors.size == 1 ? 'is' : 'are'} not told. Let them know yourself.") if contractors.any?
    lines
  end

  def status(phase, new_status)
    event = { 'in_progress' => 'phase_started', 'completed' => 'phase_completed' }[new_status.to_s]
    return [quiet('The customer is not told.')] unless event

    dealer_phase, dealer_name = dealer_side_of(phase)
    lines = []
    if dealer_phase != phase
      lines << tell("#{dealer_name}'s project follows, because they handed you this phase.")
    end
    who = customer_recipients(dealer_phase, event)
    lines << if who.any?
               tell("The customer hears#{dealer_phase != phase ? " under #{dealer_name}'s name" : ''}: #{who.to_sentence}.")
             else
               quiet('The customer is not told.')
             end
    lines
  end

  def add_task(phase)
    other = handed_to(phase)
    return [quiet('No one else is told.')] unless other

    [
      choice("#{phase.name} is run by #{other.name}. The task stays on your project unless you send it to them."),
      quiet("Sending it adds it to their job, tells them (bell, email and Review Updates), and holds #{phase.name} until they " \
            'send a change order or say there is no charge.')
    ]
  end

  def edit_task(phase)
    other = handed_to(phase)
    return [quiet('No one else is told about a task change.')] unless other

    [
      choice("#{other.name} keeps their copy as it was unless you send this change."),
      quiet("Sending it updates their copy, tells them, and holds #{phase.name} until they answer.")
    ]
  end

  def as_json_for(lines)
    { lines: lines.map(&:to_h) }
  end

  private

  def tell(text) = Line.new(text: text, tone: 'tell')
  def quiet(text) = Line.new(text: text, tone: 'quiet')
  def choice(text) = Line.new(text: text, tone: 'choice')

  # The linked company on the other end of this phase, when the hand-off is live.
  def other_company(phase)
    handed_to(phase) || handed_from(phase)&.dealer_company
  end

  def handed_to(phase)
    ProjectLinkScope.map_for(phase)&.project_link&.installer_company
  end

  def handed_from(phase)
    ProjectLinkPhase.joins(:project_link).includes(:project_link)
                    .where(installer_phase_id: phase.id, project_links: { status: 'accepted' }).first&.project_link
  end

  def dealer_side_of(phase)
    pl = handed_from(phase)
    return [phase, nil] unless pl

    map = ProjectLinkPhase.find_by(project_link_id: pl.id, installer_phase_id: phase.id)
    [map&.dealer_phase || phase, pl.dealer_company.name]
  end

  def customer_recipients(phase, event)
    project = phase.project
    prefs = project.notification_preferences.active.for_event(event).to_a
    sent = prefs.filter_map do |p|
      ways = [('email' if p.via_email && p.effective_email.present?), ('text' if p.via_sms && p.effective_phone.present?)].compact
      next if ways.empty?

      "#{p.recipient.try(:full_name).presence || p.effective_email || 'a contact'} by #{ways.join(' and ')}"
    end
    return sent if sent.any? { |s| s.include?('email') }

    if ProjectNotificationService.client_should_hear?(project, phase, event)
      email = ProjectNotificationService.send(:resolve_client_email, project) rescue nil
      sent << "#{project.customer_display_name.presence || 'the customer'} by email#{email.present? ? " (#{email})" : ''}" if email.present?
    end
    sent
  end

  def contractor_names(phases)
    task_ids = ProjectPhaseTask.where(project_phase_id: phases.map(&:id)).pluck(:id)
    ContractorAssignment.where(assignable_type: 'ProjectPhaseTask', assignable_id: task_ids)
                        .where.not(status: %w[completed declined]).includes(:contractor)
                        .map { |a| a.contractor&.name }.compact.uniq
  end
end

# frozen_string_literal: true

# Keeps a handed-off phase the same in both companies (E68 step 5d).
#
# Installer to dealer: status, started and completed, and estimated dates.
# The dealer's phase is written through Project#set_phase_status!, so the
# customer's phase emails and texts go out under the dealer's name exactly as
# when the dealer changes it. Dealer to installer: estimated dates only (either
# company can move the install dates). The last change wins, and both
# companies' link log says who moved what.
class ProjectLinkSync
  DATE_FIELDS = %w[estimated_start_date estimated_completion_date].freeze

  def initialize(phase)
    @phase = phase
  end

  def run
    map = ProjectLinkPhase.includes(project_link: :company_link)
                          .where(dealer_phase_id: @phase.id).or(ProjectLinkPhase.where(installer_phase_id: @phase.id))
                          .first
    return unless map&.installer_phase && map.project_link.accepted? && map.project_link.company_link.active?

    Current.set(project_link_sync: true) do
      if map.installer_phase_id == @phase.id
        to_dealer(map)
      else
        to_installer(map)
      end
    end
  end

  private

  def to_dealer(map)
    src = map.installer_phase
    dst = map.dealer_phase.reload
    pl = map.project_link
    changed = []

    if src.status != dst.status
      result = dst.project.set_phase_status!(dst, src.status)
      raise result[:error] if result.is_a?(Hash) && result[:error]

      dst.reload
      dst.update_columns(started_at: src.started_at, completed_at: src.completed_at)
      changed << "#{dst.name} is now #{src.status.humanize.downcase}"
    end
    changed.concat(copy_dates(src, dst))
    log(pl, pl.installer_company, changed)
    finish_if_done(pl)
  end

  def to_installer(map)
    src = map.dealer_phase
    dst = map.installer_phase.reload
    log(map.project_link, map.project_link.dealer_company, copy_dates(src, dst))
  end

  def copy_dates(src, dst)
    attrs = DATE_FIELDS.each_with_object({}) { |f, h| h[f] = src[f] if src[f] != dst[f] }
    return [] if attrs.empty?

    dst.update!(attrs)
    attrs.map { |f, v| "#{dst.name} #{f.sub('estimated_', 'estimated ').tr('_', ' ')} #{v ? v.to_date.strftime('%b %-d, %Y') : 'cleared'}" }
  end

  def log(pl, by_company, changes)
    return if changes.empty?

    pl.company_link.log!('synced', "#{by_company.name}: #{changes.join('; ')}", company: by_company, project_link: pl)
  end

  # Every handed-off phase finished or skipped: the job is done on both sides.
  def finish_if_done(pl)
    return unless pl.link_phases.includes(:installer_phase).all? { |m| m.installer_phase&.status.in?(%w[completed skipped]) }

    pl.update!(status: 'done')
    pl.company_link.log!('job_done', "#{pl.scope_label} is done", company: pl.installer_company, project_link: pl)
  end
end

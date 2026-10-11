# frozen_string_literal: true

# Monday's help digest for whoever reviews it (backlog E75): what changed that
# week, the help drafted for it, and the tours waiting for a person to play
# and approve. System-facing, so it uses the platform brand.
class GuideDigestMailer < ApplicationMailer
  def weekly(release_id)
    @release = Knowledge::ChangeQueueItem.find(release_id)
    @drafts = @release.drafts || {}
    @items = Knowledge::ChangeQueueItem.where(entity_type: 'atlas_entry')
                                       .where("context ->> 'week' = ?", @release.context['week'])
                                       .order(:created_at)
    @new_tours = @items.select { |i| Array(i.drafts&.dig('tour', 'steps')).any? }
    @tours_to_approve = Tour.active.where(approved_at: nil).order(:name)
    @brand = Brand.current
    @review_url = "#{@brand.app_url.to_s.chomp('/')}/admin/knowledge"

    mail(
      to: Guide::WeeklyDigest.recipient,
      from: default_from_address,
      subject: "Help digest for the week of #{@release.context['week']}: " \
               "#{@items.size} to review, #{@tours_to_approve.size} #{'tour'.pluralize(@tours_to_approve.size)} to approve"
    )
  end
end

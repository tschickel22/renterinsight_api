# frozen_string_literal: true

# Review Updates items that need action and have waited a day (E87): one
# reminder per person, listing what is waiting, by email (their "Project Items
# Still Waiting" switch in Notification Center). Each item is nudged once.
#
# An item assigned to someone goes to them; one assigned to nobody goes to the
# project's owner, else the company's admins.
class ReviewItemNudgeJob < ApplicationJob
  queue_as :low

  WAIT = 24.hours
  LISTED = 5

  def perform
    due = ReviewItem.open.actionable.where(nudged_at: nil).where('created_at <= ?', WAIT.ago).includes(:company, :project)
    due.group_by(&:company).each do |company, items|
      next unless company

      by_user = Hash.new { |hash, key| hash[key] = [] }
      items.each { |item| recipients_for(company, item).each { |u| by_user[u] << item } }
      by_user.each { |user, list| nudge(company, user, list) }
      ReviewItem.where(id: items.map(&:id)).update_all(nudged_at: Time.current)
    end
  end

  private

  def recipients_for(company, item)
    user = item.assigned_user || item.project&.owner
    return [user] if user&.active? && user.company_id == company.id

    company.users.where(status: 'active').select(&:effective_admin?)
  end

  def nudge(company, user, items)
    lines = items.first(LISTED).map(&:title)
    lines << "and #{items.size - LISTED} more" if items.size > LISTED
    count = "#{items.size} #{'item'.pluralize(items.size)}"
    NotificationService.create(
      recipient: user, notification_type: :project_review_nudge, company_id: company.id,
      title: "#{count} still waiting on you", message: "Waiting more than a day: #{lines.join('; ')}.",
      action_url: '/projects/reviews', action_text: 'Open Review Updates', push: false, deliver_now: true
    )
  rescue => e
    Rails.logger.error("[ReviewItemNudgeJob] user #{user&.id}: #{e.class}: #{e.message}")
  end
end

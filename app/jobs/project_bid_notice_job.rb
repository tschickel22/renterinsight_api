# frozen_string_literal: true

# Bid emails and texts to contractors (E68 step 4), sent outside the request
# so asking ten contractors doesn't keep the dealer waiting on ten emails.
class ProjectBidNoticeJob < ApplicationJob
  queue_as :default

  KINDS = %w[requested awarded awarded_elsewhere closed changed_by_dealer].freeze

  def perform(bid_id, kind)
    bid = ProjectBid.find_by(id: bid_id)
    return unless bid && KINDS.include?(kind)

    case kind
    when 'requested' then ProjectNotificationService.notify_bid_requested(bid)
    when 'awarded' then ProjectNotificationService.notify_bid_awarded(bid)
    when 'changed_by_dealer' then ProjectNotificationService.notify_bid_changed_by_dealer(bid)
    when 'awarded_elsewhere' then ProjectNotificationService.notify_bid_closed(bid, awarded: true)
    when 'closed' then ProjectNotificationService.notify_bid_closed(bid, awarded: false)
    end
  end
end

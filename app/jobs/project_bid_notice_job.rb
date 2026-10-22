# frozen_string_literal: true

# Bid emails and texts to contractors (E68 step 4), sent outside the request
# so asking ten contractors doesn't keep the dealer waiting on ten emails.
class ProjectBidNoticeJob < ApplicationJob
  queue_as :default

  KINDS = %w[requested awarded_elsewhere closed].freeze

  def perform(bid_id, kind)
    bid = ProjectBid.find_by(id: bid_id)
    return unless bid && KINDS.include?(kind)

    case kind
    when 'requested' then ProjectNotificationService.notify_bid_requested(bid)
    when 'awarded_elsewhere' then ProjectNotificationService.notify_bid_closed(bid, awarded: true)
    when 'closed' then ProjectNotificationService.notify_bid_closed(bid, awarded: false)
    end
  end
end

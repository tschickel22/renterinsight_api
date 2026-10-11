# frozen_string_literal: true

module Guide
  class DraftReleaseItemJob < ApplicationJob
    queue_as :low

    def perform(item_id)
      item = Knowledge::ChangeQueueItem.find_by(id: item_id)
      return unless item && %w[pending failed].include?(item.draft_status)

      Guide::ReleaseDrafter.new(item).draft!
    end
  end
end

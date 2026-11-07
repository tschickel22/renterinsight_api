# frozen_string_literal: true

# Reads busy times from reps' own calendar feeds (E96 phase 2). With a user
# id, that rep now (they just pasted the address); without, every rep with a
# feed, every 15 minutes.
class BusyFeedSyncJob < ApplicationJob
  queue_as :low

  def perform(user_id = nil)
    scope = User.where.not(busy_feed_url: [nil, ''])
    scope = scope.where(id: user_id) if user_id
    scope.find_each { |user| CalendarFeeds::BusyReader.sync!(user) if user.active? }
  end
end

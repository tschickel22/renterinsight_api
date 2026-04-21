# frozen_string_literal: true

# Tick job (every 5 minutes). Finds posts that should be published now and
# enqueues PublishSocialPostJob for each.
#
# Two conditions qualify:
#   1. status='scheduled' and scheduled_at <= now
#   2. status='approved' and originated from an auto-schedule
#      (generation_context contains a schedule_id). Manually-approved posts
#      stay in 'approved' until a user hits /publish explicitly — the cron
#      only auto-fires for posts the scheduler itself produced.
class PublishDueSocialPostsJob < ApplicationJob
  queue_as :default

  def perform
    scheduled = SocialPost.active.where(status: 'scheduled').where('scheduled_at <= ?', Time.current)
    auto_approved = SocialPost.active.where(status: 'approved')
                              .where("(generation_context ->> 'schedule_id') IS NOT NULL")

    enqueued = 0
    (scheduled.ids + auto_approved.ids).uniq.each do |post_id|
      PublishSocialPostJob.perform_later(post_id)
      enqueued += 1
    end

    Rails.logger.info "[PublishDueSocialPostsJob] enqueued=#{enqueued}"
  end
end

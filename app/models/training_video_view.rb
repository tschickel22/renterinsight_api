# frozen_string_literal: true

# How far one person got in one training video (E88). Written by the player
# every few seconds; a video counts as watched at 90 percent.
class TrainingVideoView < ApplicationRecord
  DONE = 0.9

  belongs_to :training_video
  belongs_to :user

  # position: where the player is now; seconds: watched since the last call;
  # started: a new play.
  def self.record!(user:, video:, position:, seconds:, started: false)
    view = find_or_initialize_by(user_id: user.id, training_video_id: video.id)
    view.company_id ||= user.company_id
    view.furthest_seconds = [view.furthest_seconds.to_i, position.to_i].max
    view.watched_seconds += seconds.to_i.clamp(0, 120)
    view.plays += 1 if started || view.new_record?
    view.last_watched_at = Time.current
    length = video.duration_seconds.to_i
    view.completed_at ||= Time.current if length.positive? && view.furthest_seconds >= (length * DONE).floor
    view.save!
    view
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def as_progress_json
    { furthest_seconds: furthest_seconds, completed: completed_at.present?, completed_at: completed_at, last_watched_at: last_watched_at }
  end
end

# frozen_string_literal: true

# One request made by a watched user. Append only; nothing edits these.
class WatchedRequest < ApplicationRecord
  belongs_to :user_activity_watch
  belongs_to :user
  belongs_to :company

  scope :navigations, -> { where(is_poll: false) }
  scope :chronological, -> { order(occurred_at: :asc) }
end

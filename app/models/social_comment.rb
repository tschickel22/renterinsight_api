# frozen_string_literal: true

class SocialComment < ApplicationRecord
  belongs_to :company
  belongs_to :social_post
  belongs_to :replied_by_user, class_name: 'User', optional: true

  validates :external_comment_id, presence: true

  scope :active,     -> { where(is_deleted: [false, nil], status: 'active') }
  scope :unread,     -> { where(read_at: nil, is_from_page: false) }
  scope :top_level,  -> { where(parent_comment_id: nil) }
  scope :replies_to, ->(comment_id) { where(parent_comment_id: comment_id) }
  scope :from_audience, -> { where(is_from_page: [false, nil]) }
end

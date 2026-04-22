# frozen_string_literal: true

class SocialAccount < ApplicationRecord
  belongs_to :company
  belongs_to :location, optional: true

  has_many :social_posts, dependent: :nullify

  encrypts :access_token_encrypted

  validates :platform, :account_type, :external_id, presence: true

  scope :active, -> { where(status: 'active', is_deleted: [false, nil]) }
  scope :for_platform, ->(platform) { where(platform: platform) }
end

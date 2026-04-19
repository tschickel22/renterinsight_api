# frozen_string_literal: true

class SocialPost < ApplicationRecord
  include WebhookNotifiable

  belongs_to :company
  belongs_to :location, optional: true
  belongs_to :social_account, optional: true
  belongs_to :vehicle, optional: true
  belongs_to :created_by_user, class_name: 'User', optional: true
  belongs_to :nurture_sequence, optional: true

  has_many :leads, foreign_key: :social_post_id, dependent: :nullify

  scope :active,    -> { where(is_deleted: [false, nil]) }
  scope :published, -> { where(status: 'published') }
  scope :scheduled, -> { where(status: 'scheduled') }
end

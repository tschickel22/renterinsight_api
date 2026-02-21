# frozen_string_literal: true

class SmsReplyToken < ApplicationRecord
  belongs_to :company
  belongs_to :sender_user, class_name: 'User', foreign_key: 'sender_user_id'

  validates :token, presence: true, uniqueness: true
  validates :communication_id, presence: true
  validates :sender_user_id, presence: true
  validates :contact_phone, presence: true
  validates :expires_at, presence: true

  scope :valid, -> { where('expires_at > ?', Time.current) }
  scope :for_communication, ->(comm_id) { where(communication_id: comm_id) }

  def expired?
    expires_at < Time.current
  end

  def mark_used!
    update!(used_at: Time.current)
  end

  # Generate a new token for a given outbound communication and sender
  def self.generate_for(communication:, sender_user:, company:, contact_phone:)
    # Reuse an unexpired token for the same communication + sender if one exists
    existing = valid.find_by(communication_id: communication.id, sender_user_id: sender_user.id)
    return existing if existing

    create!(
      token:            SecureRandom.urlsafe_base64(32),
      company:          company,
      communication_id: communication.id,
      sender_user_id:   sender_user.id,
      contact_phone:    contact_phone,
      expires_at:       72.hours.from_now
    )
  end
end

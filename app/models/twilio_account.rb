# frozen_string_literal: true

class TwilioAccount < ApplicationRecord
  belongs_to :company

  encrypts :auth_token

  validates :sub_account_sid, presence: true, uniqueness: true
  validates :phone_number, presence: true, uniqueness: true,
            format: { with: /\A\+1\d{10}\z/, message: "must be in E.164 format (e.g., +15551234567)" }
  validates :phone_number_sid, presence: true
  validates :status, presence: true, inclusion: { in: %w[provisioning active suspended failed] }

  scope :active, -> { where(status: 'active') }
  scope :provisioning, -> { where(status: 'provisioning') }

  def active? = status == 'active'
  def suspended? = status == 'suspended'
  def failed? = status == 'failed'
  def provisioning? = status == 'provisioning'

  def mark_active!
    update!(status: 'active', provisioned_at: Time.current)
  end

  def mark_failed!(error_message = nil)
    meta = metadata || {}
    meta['last_error'] = error_message
    meta['failed_at'] = Time.current.iso8601
    update!(status: 'failed', metadata: meta)
  end

  def mark_suspended!
    update!(status: 'suspended')
  end
end

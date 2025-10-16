# frozen_string_literal: true

class PasswordResetToken < ApplicationRecord
  validates :token_digest, presence: true, uniqueness: true
  validates :identifier, presence: true
  validates :user_type, presence: true, inclusion: { in: %w[client admin] }
  validates :delivery_method, presence: true, inclusion: { in: %w[email sms] }
  validates :expires_at, presence: true

  scope :active, -> { where(used: false).where('expires_at > ?', Time.current) }
  scope :expired, -> { where('expires_at <= ?', Time.current) }
  scope :by_identifier, ->(identifier) { where(identifier: identifier) }

  def self.create_for_user(user:, user_type:, identifier:, delivery_method:, ip_address: nil, user_agent: nil)
    # Generate token or code based on delivery method
    if delivery_method == 'sms'
      raw_token = generate_sms_code
      expiration = 15.minutes.from_now
    else
      raw_token = generate_email_token
      expiration = 1.hour.from_now
    end

    # Hash the token for storage
    token_digest = Digest::SHA256.hexdigest(raw_token)

    # Invalidate any existing active tokens for this identifier
    active.by_identifier(identifier).update_all(used: true)

    # Create new token
    token_record = create!(
      token_digest: token_digest,
      identifier: identifier,
      user_type: user_type,
      user_id: user&.id,
      delivery_method: delivery_method,
      expires_at: expiration,
      ip_address: ip_address,
      user_agent: user_agent
    )

    [token_record, raw_token]
  end

  def self.find_valid_token(raw_token)
    token_digest = Digest::SHA256.hexdigest(raw_token)
    active.find_by(token_digest: token_digest)
  end

  def mark_as_used!
    update!(used: true)
  end

  def increment_attempts!
    increment!(:attempts)
  end

  def expired?
    expires_at <= Time.current
  end

  def valid_for_reset?
    !used && !expired?
  end

  private

  def self.generate_email_token
    SecureRandom.urlsafe_base64(32)
  end

  def self.generate_sms_code
    # Generate 6-digit code
    format('%06d', rand(1_000_000))
  end
end

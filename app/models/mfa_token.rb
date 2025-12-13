# frozen_string_literal: true

class MfaToken < ApplicationRecord
  # Polymorphic association - works with User and BuyerPortalAccess
  belongs_to :user, polymorphic: true

  validates :token_digest, presence: true, uniqueness: true
  validates :identifier, presence: true
  validates :user_type, presence: true
  validates :delivery_method, presence: true, inclusion: { in: %w[email sms] }
  validates :expires_at, presence: true

  scope :active, -> { where(used_at: nil).where('expires_at > ?', Time.current) }
  scope :expired, -> { where('expires_at <= ?', Time.current) }
  scope :by_identifier, ->(identifier) { where(identifier: identifier) }
  scope :recent, ->(since: 1.hour.ago) { where('created_at > ?', since) }

  # Create MFA token for a user
  def self.create_for_user(user:, user_type:, identifier:, delivery_method:, ip_address: nil, user_agent: nil)
    # Generate 6-digit code (always for MFA, regardless of delivery method)
    raw_code = generate_code
    
    # MFA codes expire in 5 minutes
    expiration = 5.minutes.from_now

    # Hash the code for storage
    token_digest = Digest::SHA256.hexdigest(raw_code)

    # Invalidate any existing active tokens for this user
    where(user: user, user_type: user_type)
      .active
      .update_all(used_at: Time.current)

    # Create new token
    token_record = create!(
      token_digest: token_digest,
      user: user,
      user_type: user_type,
      identifier: identifier,
      delivery_method: delivery_method,
      expires_at: expiration,
      ip_address: ip_address,
      user_agent: user_agent
    )

    [token_record, raw_code]
  end

  # Find valid token by raw code
  def self.find_valid_token(raw_code)
    token_digest = Digest::SHA256.hexdigest(raw_code)
    active.find_by(token_digest: token_digest)
  end

  # Check rate limiting for a user
  def self.rate_limited?(user:, user_type:, window: 15.minutes, max_attempts: 3)
    recent(since: window.ago)
      .where(user: user, user_type: user_type)
      .count >= max_attempts
  end

  # Mark token as used
  def mark_as_used!
    update!(used_at: Time.current)
  end

  # Increment failed attempts
  def increment_attempts!
    increment!(:attempts)
  end

  # Check if token is expired
  def expired?
    expires_at <= Time.current
  end

  # Check if token is valid
  def valid_for_verification?
    used_at.nil? && !expired? && attempts < 5
  end

  private

  # Generate 6-digit code for MFA
  def self.generate_code
    format('%06d', SecureRandom.random_number(1_000_000))
  end
end

# frozen_string_literal: true

class BuyerPortalAccess < ApplicationRecord
  has_secure_password
  
  belongs_to :buyer, polymorphic: true
  
  # Serialize preference_history as JSON for SQLite compatibility
  serialize :preference_history, coder: JSON
  
  validates :email, presence: true, 
                    uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email_opt_in, inclusion: { in: [true, false] }
  validates :sms_opt_in, inclusion: { in: [true, false] }
  validates :marketing_opt_in, inclusion: { in: [true, false] }
  validates :portal_enabled, inclusion: { in: [true, false] }
  
  before_save :downcase_email
  after_initialize :set_defaults
  before_update :track_preference_changes
  
  # Scopes
  scope :active, -> { where(portal_enabled: true) }
  scope :inactive, -> { where(portal_enabled: false) }
  scope :email_enabled, -> { where(email_opt_in: true) }
  scope :sms_enabled, -> { where(sms_opt_in: true) }
  scope :marketing_enabled, -> { where(marketing_opt_in: true) }
  
  def generate_reset_token
    self.reset_token = SecureRandom.urlsafe_base64(32)
    self.reset_token_expires_at = 1.hour.from_now
    save!
  end
  
  def generate_login_token
    self.login_token = SecureRandom.urlsafe_base64(32)
    self.login_token_expires_at = 15.minutes.from_now
    save!
  end
  
  def reset_token_valid?
    reset_token_expires_at.present? && reset_token_expires_at > Time.current
  end
  
  def login_token_valid?
    login_token_expires_at.present? && login_token_expires_at > Time.current
  end
  
  def record_login!(ip_address)
    update!(
      last_login_at: Time.current,
      login_count: login_count + 1,
      last_login_ip: ip_address
    )
  end
  
  def preference_summary
    {
      email_opt_in: email_opt_in,
      sms_opt_in: sms_opt_in,
      marketing_opt_in: marketing_opt_in,
      portal_enabled: portal_enabled
    }
  end

  def recent_preference_changes(limit = 50)
    return [] if preference_history.nil? || preference_history.empty?
    
    preference_history.last(limit)
  end
  
  private
  
  def downcase_email
    self.email = email.downcase if email.present?
  end
  
  def set_defaults
    self.preference_history ||= []
  end

  def track_preference_changes
    # Only track changes to preference fields
    tracked_fields = %w[email_opt_in sms_opt_in marketing_opt_in portal_enabled]
    changed_fields = tracked_fields & changed

    return if changed_fields.empty?

    # Build change entry
    change_entry = {
      timestamp: Time.current.iso8601,
      changes: {}
    }

    changed_fields.each do |field|
      change_entry[:changes][field] = {
        from: changes[field][0],
        to: changes[field][1]
      }
    end

    # Initialize preference_history if nil
    self.preference_history ||= []

    # Append new change
    self.preference_history = preference_history + [change_entry]
  end
end

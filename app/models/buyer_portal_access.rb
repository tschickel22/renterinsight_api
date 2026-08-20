# frozen_string_literal: true

class BuyerPortalAccess < ApplicationRecord
  has_secure_password validations: false
  
  # Custom password validations
  validates :password, length: { minimum: 6 }, allow_nil: true
  validates :password, presence: true, length: { minimum: 6 }, if: :password_required_for_authentication?
  
  belongs_to :buyer, polymorphic: true
  belongs_to :company, optional: true
  
  # Convenience method to get the Contact when buyer_type is 'Contact'
  def contact
    buyer if buyer_type == 'Contact'
  end
  
  # Serialize preference_history as JSON for SQLite compatibility
  serialize :preference_history, coder: JSON
  # permissions column is already JSON type - no serialization needed
  
  validates :email, presence: true, 
                    uniqueness: { case_sensitive: false },
                    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :email_opt_in, inclusion: { in: [true, false] }
  validates :sms_opt_in, inclusion: { in: [true, false] }
  validates :marketing_opt_in, inclusion: { in: [true, false] }
  validates :portal_enabled, inclusion: { in: [true, false] }

  # Phones allowed to unlock this portal login with Face ID or a fingerprint.
  has_many :device_sessions, as: :owner, dependent: :destroy

  # A password change, or a dealer switching portal access off, has to reach the
  # phones. Biometric unlock bypasses the password by design, so leaving those
  # sessions alive would mean a customer who was cut off still had a device that
  # never needed the credential they lost.
  after_update_commit :revoke_device_sessions_after_credential_change,
                      if: -> { saved_change_to_password_digest? || turned_portal_access_off? }
  
  before_save :downcase_email
  after_initialize :set_defaults
  before_update :track_preference_changes
  
  # Scopes
  scope :active, -> { where(portal_enabled: true) }
  scope :inactive, -> { where(portal_enabled: false) }
  scope :email_enabled, -> { where(email_opt_in: true) }
  scope :sms_enabled, -> { where(sms_opt_in: true) }
  scope :marketing_enabled, -> { where(marketing_opt_in: true) }
  scope :for_company, ->(company_id) { where(company_id: company_id) }
  scope :by_status, ->(status) { where(status: status) }
  
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
  
  def generate_invitation_token
    self.invitation_token = SecureRandom.urlsafe_base64(32)
    self.invitation_token_expires_at = 7.days.from_now
    self.status = 'Invited'
    save!
  end
  
  def invitation_token_valid?
    invitation_token_expires_at.present? && 
    invitation_token_expires_at > Time.current &&
    invitation_accepted_at.nil?
  end
  
  def accept_invitation!(first_name, last_name, password)
    transaction do
      # Update the associated Contact's name if buyer_type is Contact
      if buyer_type == 'Contact' && buyer.present?
        buyer.update!(
          first_name: first_name,
          last_name: last_name
        )
        
        # Set company_id from the associated contact
        self.company_id = buyer.company_id if buyer.respond_to?(:company_id)
      end
      
      # Update BuyerPortalAccess - set password directly
      self.password = password
      self.invitation_accepted_at = Time.current
      self.status = 'Active'
      self.portal_enabled = true
      self.invitation_token = nil
      self.invitation_token_expires_at = nil
      save!
    end
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
  
  def password_required_for_authentication?
    # Only require password validation when explicitly setting a new password
    # Don't require it during invitation creation or other updates
    password.present?
  end
  
  def downcase_email
    self.email = email.downcase if email.present?
  end
  
  def set_defaults
    self.preference_history ||= []
    self.permissions ||= []
    self.role ||= 'Client'
    self.status ||= 'Pending'
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

  private

  def turned_portal_access_off?
    saved_change_to_portal_enabled? && portal_enabled == false
  end

  def revoke_device_sessions_after_credential_change
    DeviceSession.revoke_all_for(self, 'credentials_changed')
  rescue StandardError => e
    Rails.logger.error("[DeviceSession] Could not revoke for portal access #{id}: #{e.message}")
  end
end

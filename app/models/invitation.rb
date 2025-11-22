# frozen_string_literal: true

class Invitation < ApplicationRecord
  # Constants
  INVITATION_TYPES = %w[company_user portal_user tenant].freeze
  STATUSES = %w[pending accepted expired revoked].freeze
  DELIVERY_METHODS = %w[email sms both].freeze
  LOCATION_ROLES = %w[location_admin location_manager location_staff].freeze
  TOKEN_EXPIRY = 7.days # Invitations expire after 7 days
  
  # Associations
  belongs_to :invited_by, class_name: 'User'
  belongs_to :company, optional: true
  has_many :invitation_locations, dependent: :destroy
  
  # Validations
  validates :invitation_type, inclusion: { in: INVITATION_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :delivery_method, inclusion: { in: DELIVERY_METHODS }
  validates :location_role, inclusion: { in: LOCATION_ROLES }, allow_nil: true
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :token_digest, presence: true, uniqueness: true
  validates :expires_at, presence: true
  
  validate :phone_present_if_sms_delivery
  validate :company_present_for_company_invitations
  
  # Scopes
  scope :pending, -> { where(status: 'pending') }
  scope :accepted, -> { where(status: 'accepted') }
  scope :expired, -> { where(status: 'expired') }
  scope :active, -> { where(status: 'pending').where('expires_at > ?', Time.current) }
  scope :by_type, ->(type) { where(invitation_type: type) }
  scope :for_company, ->(company_id) { where(company_id: company_id) }
  scope :recent, -> { order(created_at: :desc) }
  
  # Callbacks
  before_validation :set_expiry, on: :create
  before_validation :normalize_fields
  after_create :send_invitation
  
  # Generate and return both the invitation record and the raw token
  def self.create_for_user(
    invitation_type:,
    email:,
    phone: nil,
    invited_by:,
    company: nil,
    role: nil,
    permissions: [],
    recipient_name: nil,
    recipient_data: {},
    delivery_method: 'email',
    message: nil,
    location_ids: [],
    location_role: nil
  )
    # Generate secure token
    raw_token = SecureRandom.urlsafe_base64(32)
    token_digest = Digest::SHA256.hexdigest(raw_token)
    
    invitation = create!(
      invitation_type: invitation_type,
      email: email,
      phone: phone,
      invited_by: invited_by,
      company: company,
      role: role,
      permissions: permissions,
      recipient_name: recipient_name,
      recipient_data: recipient_data,
      delivery_method: delivery_method,
      message: message,
      token_digest: token_digest,
      status: 'pending',
      location_ids: location_ids || [],
      location_role: location_role
    )
    
    [invitation, raw_token]
  end
  
  # Find a valid invitation by token
  def self.find_valid_token(raw_token)
    token_digest = Digest::SHA256.hexdigest(raw_token)
    
    invitation = find_by(token_digest: token_digest)
    return nil unless invitation
    return nil if invitation.expired?
    return nil if invitation.accepted?
    return nil if invitation.revoked?
    
    invitation
  end
  
  # Check if invitation is expired
  def expired?
    status == 'expired' || expires_at < Time.current
  end
  
  # Check if invitation is accepted
  def accepted?
    status == 'accepted'
  end
  
  # Check if invitation is revoked
  def revoked?
    status == 'revoked'
  end
  
  # Check if invitation can be accepted
  def can_accept?
    status == 'pending' && !expired?
  end
  
  # Mark invitation as accepted
  def mark_as_accepted!(ip_address: nil, user_agent: nil)
    update!(
      status: 'accepted',
      accepted_at: Time.current,
      ip_address: ip_address,
      user_agent: user_agent
    )
  end
  
  # Mark invitation as revoked
  def revoke!(reason: nil)
    update!(
      status: 'revoked',
      notes: [notes, "Revoked: #{reason}"].compact.join("\n")
    )
  end
  
  # Resend the invitation
  def resend!
    return false unless can_accept?
    
    update!(
      resend_count: resend_count + 1,
      last_sent_at: Time.current,
      sent_at: Time.current
    )
    
    send_invitation
    true
  end
  
  # Increment attempts counter
  def increment_attempts!
    increment!(:attempts)
    
    # Auto-revoke after 10 failed attempts
    revoke!(reason: 'Too many failed attempts') if attempts >= 10
  end
  
  # Generate invitation URL
  def invitation_url
    frontend_url = ENV['FRONTEND_URL'] || 'https://localhost:5173'
    
    # Use unified invitation path for all invitation types
    path = '/invitations/accept'
    
    "#{frontend_url}#{path}?token=#{token}"
  end
  
  # Get the raw token (only if just created)
  def token
    @raw_token
  end
  
  def token=(value)
    @raw_token = value
  end
  
  # Build template context for rendering invitation templates
  def template_context
    {
      'recipient_name' => recipient_name || email.split('@').first.capitalize,
      'inviter_name' => invited_by.name || invited_by.email,
      'company_name' => company&.name,
      'invitation_url' => invitation_url,
      'expires_at' => expires_at.strftime('%B %d, %Y at %I:%M %p'),
      'role' => role,
      'location_role' => location_role,
      'message' => message
    }
  end

  # Get parsed location IDs from JSON array
  # Handles PostgreSQL jsonb column which can be Array, String, or nil
  def parsed_location_ids
    return [] if location_ids.blank?
    
    ids = case location_ids
          when Array
            location_ids
          when String
            # Handle case where jsonb is returned as JSON string
            begin
              parsed = JSON.parse(location_ids)
              parsed.is_a?(Array) ? parsed : []
            rescue JSON::ParserError
              []
            end
          else
            []
          end
    
    ids.map(&:to_i).reject(&:zero?).uniq
  end

  # Check if invitation has location assignments
  def has_location_assignments?
    parsed_location_ids.any?
  end

  # Assign user to locations after invitation acceptance
  def assign_user_to_locations(user, assigned_by: nil)
    return [] unless has_location_assignments?
    return [] unless company_id

    assignments = []
    location_role_value = location_role || 'location_staff'

    parsed_location_ids.each do |loc_id|
      location = Location.find_by(id: loc_id, company_id: company_id)
      next unless location

      user_location = UserLocation.find_or_initialize_by(
        user_id: user.id,
        location_id: location.id
      )
      
      user_location.company_id = company_id
      user_location.location_role = location_role_value
      user_location.assigned_by = assigned_by&.id&.to_s || invited_by&.id&.to_s
      user_location.active = true
      
      if user_location.save
        assignments << user_location
        Rails.logger.info "✅ [Invitation] Assigned user #{user.id} to location #{location.id} with role #{location_role_value}"
      else
        Rails.logger.error "❌ [Invitation] Failed to assign user #{user.id} to location #{location.id}: #{user_location.errors.full_messages.join(', ')}"
      end
    end

    assignments
  end
  
  private
  
  def set_expiry
    self.expires_at ||= TOKEN_EXPIRY.from_now
  end
  
  def normalize_fields
    self.email = email&.downcase&.strip
    self.phone = PhoneNumberService.normalize(phone) if phone.present?
  end
  
  def phone_present_if_sms_delivery
    if delivery_method.in?(['sms', 'both']) && phone.blank?
      errors.add(:phone, 'must be present for SMS delivery')
    end
  end
  
  def company_present_for_company_invitations
    if invitation_type.in?(['company_user', 'portal_user']) && company.blank?
      errors.add(:company, 'must be present for company/portal user invitations')
    end
  end
  
  def send_invitation
    # This will be called by InvitationService after creation
    # The token is set in the create_for_user method
    Rails.logger.info("Invitation created: #{id}, type: #{invitation_type}")
  end
end

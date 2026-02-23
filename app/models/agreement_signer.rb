class AgreementSigner < ApplicationRecord
  belongs_to :agreement
  belongs_to :signable, polymorphic: true, optional: true

  has_many :agreement_audit_logs, dependent: :nullify
  has_many :agreement_reminders, dependent: :destroy

  # Validations
  validates :name, presence: true
  validates :email, presence: true, format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :role, presence: true, inclusion: { in: %w[signer counter_signer preparer cc] }
  validates :status, presence: true, inclusion: { in: %w[pending viewed signed declined] }
  validates :access_token, presence: true, uniqueness: true

  # Role constants
  ROLE_SIGNER = 'signer'
  ROLE_COUNTER_SIGNER = 'counter_signer'
  ROLE_PREPARER = 'preparer'
  ROLE_CC = 'cc'

  # Status constants
  STATUS_PENDING = 'pending'
  STATUS_VIEWED = 'viewed'
  STATUS_SIGNED = 'signed'
  STATUS_DECLINED = 'declined'

  # Callbacks
  before_validation :generate_access_token, on: :create

  # Scopes
  scope :required_signers, -> { where(role: [ROLE_SIGNER, ROLE_COUNTER_SIGNER]) }
  scope :pending, -> { where(status: [STATUS_PENDING, STATUS_VIEWED]) }
  scope :signed, -> { where(status: STATUS_SIGNED) }
  scope :cc_recipients, -> { where(role: ROLE_CC) }

  def view!(ip_address = nil, user_agent = nil)
    return if status == STATUS_SIGNED || status == STATUS_DECLINED

    update!(
      status: STATUS_VIEWED,
      viewed_at: Time.current,
      ip_address: ip_address,
      user_agent: user_agent
    )

    AgreementAuditLog.log!(
      agreement, AgreementAuditLog::ACTION_VIEWED,
      agreement_signer: self,
      ip_address: ip_address,
      user_agent: user_agent,
      performed_by: self
    )

    agreement.mark_viewed!(self)
  end

  def sign!(params = {})
    return false if status == STATUS_SIGNED || status == STATUS_DECLINED

    sig_data = {
      signature_url: params[:signature_url],
      signature_method: params[:signature_method],
      initials_url: params[:initials_url],
      initials_method: params[:initials_method],
      typed_signature: params[:typed_signature],
      typed_initials: params[:typed_initials],
      signature_font: params[:signature_font],
      ip_address: params[:ip_address],
      user_agent: params[:user_agent],
      signed_at: Time.current,
      status: STATUS_SIGNED,
      signature_hash: generate_signature_hash(params)
    }

    update!(sig_data)

    AgreementAuditLog.log!(
      agreement, AgreementAuditLog::ACTION_SIGNED,
      agreement_signer: self,
      ip_address: params[:ip_address],
      user_agent: params[:user_agent],
      performed_by: self,
      metadata: { method: params[:signature_method] }
    )

    # Check if all required signers have signed
    if agreement.all_signed?
      agreement.complete!
    else
      agreement.mark_partially_signed!
    end

    true
  end

  def decline!(reason = nil, ip_address = nil, user_agent = nil)
    return false if status == STATUS_SIGNED

    update!(
      status: STATUS_DECLINED,
      declined_at: Time.current,
      decline_reason: reason,
      ip_address: ip_address,
      user_agent: user_agent
    )

    AgreementAuditLog.log!(
      agreement, AgreementAuditLog::ACTION_DECLINED,
      agreement_signer: self,
      ip_address: ip_address,
      user_agent: user_agent,
      performed_by: self,
      metadata: { reason: reason }
    )

    agreement.decline!(self)
    true
  end

  def signing_url
    "/sign/#{access_token}"
  end

  def requires_signature?
    [ROLE_SIGNER, ROLE_COUNTER_SIGNER, ROLE_PREPARER].include?(role)
  end

  def is_cc?
    role == ROLE_CC
  end

  private

  def generate_access_token
    self.access_token ||= SecureRandom.urlsafe_base64(32)
  end

  def generate_signature_hash(params)
    data = "#{id}|#{params[:signature_url]}|#{params[:ip_address]}|#{Time.current.to_i}"
    Digest::SHA256.hexdigest(data)
  end
end

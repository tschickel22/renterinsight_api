class CampaignSuppression < ApplicationRecord
  REASONS = %w[unsubscribe bounce_hard complaint manual sms_stop].freeze
  CONTACT_TYPES = %w[email phone].freeze

  # Reasons that disqualify an address from ANY further email, marketing or not.
  # A hard bounce means the mailbox does not exist; a complaint means the recipient
  # reported us as spam. Both are counted by SES against the whole account's reputation,
  # so each retry to a known-bad address spends sending standing that every other tenant
  # on the platform shares.
  #
  # Deliberately narrower than the full REASONS list. An unsubscribe is a marketing
  # preference, not a dead mailbox: someone who opted out of campaigns must still receive
  # the quote they asked a salesperson for.
  UNMAILABLE_REASONS = %w[bounce_hard complaint].freeze

  belongs_to :company
  belongs_to :source_campaign, class_name: 'Campaign', optional: true

  validates :reason, presence: true, inclusion: { in: REASONS }
  validates :email_address, uniqueness: { scope: :company_id, case_sensitive: false }, if: -> { email_address.present? }
  validates :phone_number, uniqueness: { scope: :company_id }, if: -> { phone_number.present? }
  validate :exactly_one_contact_value

  before_validation :downcase_email
  before_validation :normalize_phone
  before_validation :stamp_suppressed_at

  scope :for_email, ->(email) { where(email_address: email.to_s.downcase.strip) }
  scope :for_phone, ->(phone) { where(phone_number: normalize_phone_static(phone)) }

  def self.suppressed?(company_id, contact_value)
    return false if contact_value.blank?
    if contact_value.to_s.include?('@')
      where(company_id: company_id, email_address: contact_value.to_s.downcase.strip).exists?
    else
      where(company_id: company_id, phone_number: normalize_phone_static(contact_value)).exists?
    end
  end

  # True when this address has permanently failed for this company. Used by every outbound
  # email path, not just campaigns, so a bounce recorded by one campaign also stops the
  # one-off email a rep sends from the lead screen an hour later.
  def self.unmailable?(company_id, email)
    return false if company_id.blank? || email.blank?

    where(company_id: company_id, reason: UNMAILABLE_REASONS)
      .where(email_address: email.to_s.downcase.strip)
      .exists?
  end

  # Addresses this company must not email, as a scope, for filtering an audience in SQL
  # rather than one existence check per candidate record.
  def self.unmailable_emails_for(company_id)
    where(company_id: company_id, reason: UNMAILABLE_REASONS)
      .where.not(email_address: nil)
      .select(:email_address)
  end

  def self.normalize_phone_static(phone)
    digits = phone.to_s.gsub(/\D/, '')
    return nil if digits.blank?
    if digits.length == 10
      "+1#{digits}"
    elsif digits.length == 11 && digits.start_with?('1')
      "+#{digits}"
    else
      "+#{digits}"
    end
  end

  def email_suppression? = email_address.present?
  def phone_suppression? = phone_number.present?

  private

  def exactly_one_contact_value
    has_email = email_address.present?
    has_phone = phone_number.present?
    if !has_email && !has_phone
      errors.add(:base, 'Either email_address or phone_number must be present')
    elsif has_email && has_phone
      errors.add(:base, 'Suppression must have either email_address OR phone_number, not both')
    end
  end

  def downcase_email
    self.email_address = email_address.to_s.downcase.strip if email_address.present?
  end

  def normalize_phone
    return if phone_number.blank?
    self.phone_number = self.class.normalize_phone_static(phone_number)
  end

  def stamp_suppressed_at
    self.suppressed_at ||= Time.current
  end
end

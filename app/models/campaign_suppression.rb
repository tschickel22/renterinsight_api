class CampaignSuppression < ApplicationRecord
  REASONS = %w[unsubscribe bounce_hard complaint manual].freeze

  belongs_to :company
  belongs_to :source_campaign, class_name: 'Campaign', optional: true

  validates :email_address, :reason, presence: true
  validates :reason, inclusion: { in: REASONS }
  validates :email_address, uniqueness: { scope: :company_id, case_sensitive: false }

  before_validation :downcase_email
  before_validation :stamp_suppressed_at

  def self.suppressed?(company_id, email_address)
    return false if email_address.blank?
    where(company_id: company_id, email_address: email_address.to_s.downcase.strip).exists?
  end

  private

  def downcase_email
    self.email_address = email_address.to_s.downcase.strip if email_address
  end

  def stamp_suppressed_at
    self.suppressed_at ||= Time.current
  end
end

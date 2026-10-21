# frozen_string_literal: true

# A dealer's vendor that is also its own company on the platform (E68 step 5).
# The dealer invites by the installer admin's email; an admin with that email
# accepts from inside the installer's company, which fixes installer_company.
class CompanyLink < ApplicationRecord
  STATUSES = %w[invited active ended].freeze
  AGREEMENT_VERSION = '2026-10-17'

  belongs_to :dealer_company, class_name: 'Company'
  belongs_to :installer_company, class_name: 'Company', optional: true
  belongs_to :dealer_vendor, class_name: 'Vendor'
  belongs_to :invited_by, class_name: 'User', optional: true
  belongs_to :accepted_by, class_name: 'User', optional: true
  belongs_to :ended_by, class_name: 'User', optional: true
  belongs_to :installer_dealer_account, class_name: 'Account', optional: true
  has_many :project_links, dependent: :restrict_with_error
  has_many :events, class_name: 'CompanyLinkEvent', dependent: :delete_all
  has_many :rate_cards, class_name: 'LinkRateCard', dependent: :destroy

  validates :status, inclusion: { in: STATUSES }
  validates :invite_email, presence: true
  validate :vendor_belongs_to_dealer
  validate :not_linked_to_itself

  before_validation { self.invite_email = invite_email.to_s.strip.downcase }

  scope :active, -> { where(status: 'active') }
  scope :open, -> { where(status: %w[invited active]) }

  def active? = status == 'active'
  def invited? = status == 'invited'

  # Which side of the link a company is on.
  def side_for(company)
    return :dealer if company&.id == dealer_company_id
    return :installer if company&.id == installer_company_id

    nil
  end

  # The installer's prices in force for this dealer (E68 step 6), and a newer
  # version waiting for the dealer, if any.
  def current_rate_card
    rate_cards.approved.order(version: :desc).first
  end

  def pending_rate_card
    rate_cards.submitted.order(version: :desc).first
  end

  def log!(kind, summary, company:, user: nil, project_link: nil, data: {})
    events.create!(kind: kind, summary: summary, company: company, user: user, project_link: project_link,
                   data: data.deep_stringify_keys, created_at: Time.current)
  end

  private

  def vendor_belongs_to_dealer
    return if dealer_vendor.nil? || dealer_vendor.company_id == dealer_company_id

    errors.add(:dealer_vendor, 'must be one of the dealer\'s vendors')
  end

  def not_linked_to_itself
    errors.add(:installer_company, 'must be a different company') if installer_company_id.present? && installer_company_id == dealer_company_id
  end
end

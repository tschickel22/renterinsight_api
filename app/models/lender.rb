# frozen_string_literal: true

# A lightweight, company-scoped lender list managed in Finance settings and used as a
# quick-add dropdown on deals. Intentionally separate from Accounts (CRM partners) and
# Vendors (AP) — this is its own simple reference list, not a financial-transaction entity.
#
# Soft-delete follows the app convention (is_deleted flag), so deals that already
# reference a lender keep their denormalized lender_name even after the lender is removed.
class Lender < ApplicationRecord
  belongs_to :company
  has_many :deals, dependent: :nullify

  # Max Advance Phase 2 — per-lender calculation schedule (config only).
  has_many :allowance_items, class_name: 'LenderAllowanceItem', dependent: :destroy
  has_many :deletion_items,  class_name: 'LenderDeletionItem',  dependent: :destroy
  has_one  :markup_config,   class_name: 'LenderMarkupConfig',  dependent: :destroy

  validates :name, presence: true
  validates :email, format: { with: URI::MailTo::EMAIL_REGEXP, allow_blank: true }

  # No default scope (callers opt in explicitly via .active / .not_deleted).
  scope :active,      -> { where(active: true, is_deleted: [false, nil]) }
  scope :not_deleted, -> { where(is_deleted: [false, nil]) }
  scope :by_name,     -> { order(:name) }

  before_validation :normalize_fields
  after_create :seed_allowance_from_defaults

  def soft_delete!
    update!(is_deleted: true, active: false)
  end

  def restore!
    update!(is_deleted: false, active: true)
  end

  private

  def normalize_fields
    self.name  = name&.strip
    self.email = email&.strip&.downcase if email.present?
    self.phone = phone&.strip if phone.present?
  end

  # Auto-populate this lender's allowance schedule from company defaults.
  def seed_allowance_from_defaults
    CompanyAllowanceDefault.populate_lender(self)
  rescue => e
    Rails.logger.error "[Lender#seed_allowance_from_defaults] Failed for lender #{id}: #{e.message}"
  end
end

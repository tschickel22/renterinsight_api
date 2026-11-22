# frozen_string_literal: true

# The people on a Deal, Quote or Invoice, each with a role: Buyer, Co-Buyer,
# Co-Signer or Guarantor. The role belongs here, on the link, not on the
# Contact: the same person can co-sign one deal and buy on the next.
#
# On a Deal this list is what the people card shows and edits. The deal's
# contact_id (Buyer) and co_applicant_contact_id (Co-Buyer) are kept in step
# with it both ways (Deal#sync_people_from_pointers, #sync_pointers_from_people)
# so everything that reads those two columns keeps working.
#
# Usage:
#   deal.entity_buyers.co_buyers  # Co-buyers, guarantors, cosigners
#   deal.all_buyers               # Everyone (via Buyable concern)
#   EntityBuyer.create!(company: co, contact: jane, buyable: deal, role: 'co_buyer')
#
class EntityBuyer < ApplicationRecord
  belongs_to :company
  belongs_to :contact
  belongs_to :buyable, polymorphic: true

  # ── Roles ────────────────────────────────────────────────────────
  ROLE_BUYER     = 'buyer'.freeze
  ROLE_CO_BUYER  = 'co_buyer'.freeze
  ROLE_GUARANTOR = 'guarantor'.freeze
  ROLE_COSIGNER  = 'cosigner'.freeze

  ROLES = [ROLE_BUYER, ROLE_CO_BUYER, ROLE_COSIGNER, ROLE_GUARANTOR].freeze
  # The people buying. One Buyer; Co-Buyers can be several (the first is the
  # contract's Buyer 2, the rest are named on its buyers line).
  PURCHASER_ROLES = [ROLE_BUYER, ROLE_CO_BUYER].freeze
  # Role => label key in Company::LABEL_DEFAULTS.
  LABEL_KEYS = { ROLE_BUYER => 'buyer', ROLE_CO_BUYER => 'co_buyer',
                 ROLE_COSIGNER => 'cosigner', ROLE_GUARANTOR => 'guarantor' }.freeze

  # Set by Deal when it writes the list from its own columns, so the list does
  # not turn around and write the columns back.
  attr_accessor :skip_pointer_sync

  # ── Validations ──────────────────────────────────────────────────
  validates :role, inclusion: { in: ROLES }
  validates :contact_id, uniqueness: {
    scope: [:buyable_type, :buyable_id],
    conditions: -> { where(is_deleted: [false, nil]) },
    message: 'is already on this record'
  }
  validate :one_buyer, if: -> { (new_record? || will_save_change_to_role? || will_save_change_to_is_deleted?) && !is_deleted }

  # ── Scopes ───────────────────────────────────────────────────────
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :co_buyers, -> { where(role: [ROLE_CO_BUYER, ROLE_GUARANTOR, ROLE_COSIGNER]) }
  scope :purchasers, -> { where(role: PURCHASER_ROLES) }
  # Buyer, Co-Buyer, Co-Signer, Guarantor, then the order they were added.
  scope :ordered, -> {
    order(Arel.sql("CASE entity_buyers.role WHEN 'buyer' THEN 0 WHEN 'co_buyer' THEN 1 WHEN 'cosigner' THEN 2 WHEN 'guarantor' THEN 3 ELSE 4 END"))
      .order(:position, :created_at)
  }

  after_commit :sync_deal_pointers, unless: :skip_pointer_sync

  # ── Display Helpers ──────────────────────────────────────────────
  # The company's word for the role (Labels), e.g. "Co-Buyer" or "Co-Applicant".
  def role_label
    key = LABEL_KEYS[role]
    labels = company&.resolved_labels || {}
    (key && labels[key].presence) || role&.titleize
  end

  def buyer_name
    contact ? "#{contact.first_name} #{contact.last_name}".strip : ''
  end

  private

  def one_buyer
    return unless role == ROLE_BUYER

    taken = EntityBuyer.active.where(buyable_type: buyable_type, buyable_id: buyable_id, role: role)
    taken = taken.where.not(id: id) if persisted?
    errors.add(:role, "#{role_label} is already set on this record. Change that person's role first.") if taken.exists?
  end

  def sync_deal_pointers
    return unless buyable_type == 'Deal'

    roles = [role, *previous_changes['role']].compact & PURCHASER_ROLES
    buyable&.sync_pointers_from_people!(roles) if roles.any?
  end
end

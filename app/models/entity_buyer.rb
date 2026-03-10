# frozen_string_literal: true

# Polymorphic join table linking contacts as buyers to Deals, Quotes, and Invoices.
# The primary buyer is the main contact_id on the parent record.
# Co-buyers, guarantors, and cosigners are stored here.
#
# Usage:
#   deal.entity_buyers.co_buyers  # Get all co-buyers
#   deal.all_buyers               # Get primary + co-buyers (via Buyable concern)
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

  ROLES = [ROLE_BUYER, ROLE_CO_BUYER, ROLE_GUARANTOR, ROLE_COSIGNER].freeze

  # ── Validations ──────────────────────────────────────────────────
  validates :role, inclusion: { in: ROLES }
  validates :contact_id, uniqueness: {
    scope: [:buyable_type, :buyable_id],
    conditions: -> { where(is_deleted: [false, nil]) },
    message: 'is already a buyer on this record'
  }

  # ── Scopes ───────────────────────────────────────────────────────
  scope :active, -> { where(is_deleted: [false, nil]) }
  scope :co_buyers, -> { where(role: [ROLE_CO_BUYER, ROLE_GUARANTOR, ROLE_COSIGNER]) }
  scope :ordered, -> { order(:position, :created_at) }

  # ── Display Helpers ──────────────────────────────────────────────
  def role_label
    role&.titleize
  end

  def buyer_name
    contact ? "#{contact.first_name} #{contact.last_name}".strip : ''
  end
end

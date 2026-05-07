# frozen_string_literal: true

class JournalEntryLine < ApplicationRecord
  belongs_to :journal_entry
  belongs_to :chart_of_account
  belongs_to :location, optional: true
  belongs_to :contact, optional: true
  belongs_to :deal, optional: true
  belongs_to :vehicle, optional: true

  DEPARTMENTS = %w[new_sales used_sales service parts fi admin].freeze

  validates :chart_of_account_id, presence: true
  validates :department, inclusion: { in: DEPARTMENTS }, allow_blank: true
  validate :has_amount

  before_validation :set_default_location

  def has_amount
    if (debit_amount.blank? || debit_amount.zero?) && (credit_amount.blank? || credit_amount.zero?)
      errors.add(:base, "Line must have either a debit or credit amount")
    end
    if debit_amount.present? && debit_amount > 0 && credit_amount.present? && credit_amount > 0
      errors.add(:base, "Line cannot have both debit and credit amounts")
    end
  end

  def net_amount
    (debit_amount || 0) - (credit_amount || 0)
  end

  def bank_amount
    net_amount
  end

  private

  # Falls back to the request's current location when a caller didn't supply one
  # (e.g. manual JE form, recurring JE without a template location). Source-entity
  # services already set location_id explicitly and won't be overridden.
  def set_default_location
    return if location_id.present?
    return unless Current.respond_to?(:location_id) && Current.location_id.present?
    self.location_id = Current.location_id
  end
end

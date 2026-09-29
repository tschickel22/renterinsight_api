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
  validate :account_is_postable, if: -> { new_record? || will_save_change_to_chart_of_account_id? }

  before_validation :set_default_location

  def has_amount
    if (debit_amount.blank? || debit_amount.zero?) && (credit_amount.blank? || credit_amount.zero?)
      errors.add(:base, "Line must have either a debit or credit amount")
    end
    if debit_amount.present? && debit_amount > 0 && credit_amount.present? && credit_amount > 0
      errors.add(:base, "Line cannot have both debit and credit amounts")
    end
  end

  # A line on another company's account was summed by account id but never
  # shown, since reports only walk the company's own chart; a line on a header
  # account likewise sat outside every report.
  def account_is_postable
    return unless chart_of_account && journal_entry
    if chart_of_account.company_id != journal_entry.company_id
      errors.add(:chart_of_account_id, 'belongs to a different company')
    elsif chart_of_account.is_header?
      errors.add(:chart_of_account_id, "#{chart_of_account.account_number} is a header account and can't be posted to")
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

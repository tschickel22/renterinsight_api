# frozen_string_literal: true

class BankRule < ApplicationRecord
  belongs_to :company
  belongs_to :bank_account, optional: true
  belongs_to :assign_account, class_name: 'ChartOfAccount', optional: true
  belongs_to :assign_contact, class_name: 'Contact', optional: true

  has_many :bank_transactions, foreign_key: :rule_id

  ACTION_TYPES = %w[categorize exclude].freeze
  MATCH_TYPES = %w[contains starts_with exact regex].freeze
  MATCH_FIELDS = %w[description reference_number].freeze
  DIRECTIONS = %w[deposit withdrawal any].freeze

  validates :name, presence: true
  validates :action_type, presence: true, inclusion: { in: ACTION_TYPES }
  validates :match_type, presence: true, inclusion: { in: MATCH_TYPES }
  validates :match_field, inclusion: { in: MATCH_FIELDS }
  validates :match_value, presence: true
  validates :assign_account_id, presence: true, if: -> { action_type == 'categorize' }
  validates :transaction_direction, inclusion: { in: DIRECTIONS }

  def exclude_rule?
    action_type == 'exclude'
  end

  def categorize_rule?
    action_type == 'categorize' || action_type.blank?
  end

  scope :active, -> { where(is_active: true) }
  scope :by_priority, -> { order(:priority, :name) }
  scope :for_account, ->(bank_account_id) { where(bank_account_id: [bank_account_id, nil]) }

  def matches?(bank_transaction)
    return false unless is_active?
    return false unless direction_matches?(bank_transaction)
    return false unless amount_in_range?(bank_transaction)
    return false unless bank_account_matches?(bank_transaction)

    field_value = case match_field
                  when 'description' then bank_transaction.description
                  when 'reference_number' then bank_transaction.reference_number
                  end

    return false if field_value.blank?

    case match_type
    when 'contains'
      field_value.downcase.include?(match_value.downcase)
    when 'starts_with'
      field_value.downcase.start_with?(match_value.downcase)
    when 'exact'
      field_value.downcase == match_value.downcase
    when 'regex'
      field_value.match?(Regexp.new(match_value, Regexp::IGNORECASE))
    else
      false
    end
  rescue RegexpError
    false
  end

  def record_match!
    update_columns(
      match_count: (match_count || 0) + 1,
      last_matched_at: Time.current
    )
  end

  private

  def direction_matches?(txn)
    case transaction_direction
    when 'deposit' then txn.deposit?
    when 'withdrawal' then txn.withdrawal?
    when 'any' then true
    else true
    end
  end

  def amount_in_range?(txn)
    abs_amount = txn.amount.abs
    return false if min_amount.present? && abs_amount < min_amount
    return false if max_amount.present? && abs_amount > max_amount
    true
  end

  def bank_account_matches?(txn)
    bank_account_id.nil? || bank_account_id == txn.bank_account_id
  end
end

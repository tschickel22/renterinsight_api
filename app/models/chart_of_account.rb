# frozen_string_literal: true

class ChartOfAccount < ApplicationRecord
  belongs_to :company
  belongs_to :parent, class_name: 'ChartOfAccount', optional: true
  belongs_to :bank_account, optional: true

  has_many :children, class_name: 'ChartOfAccount', foreign_key: :parent_id, dependent: :nullify
  has_many :journal_entry_lines, dependent: :restrict_with_error
  has_many :account_links, dependent: :destroy

  TYPES = %w[asset liability equity revenue expense].freeze
  SUB_TYPES = %w[
    bank accounts_receivable accounts_payable
    cost_of_goods_sold inventory prepaid
    fixed_asset accumulated_depreciation
    current_liability long_term_liability
    owners_equity retained_earnings
    sales_revenue service_revenue other_revenue
    operating_expense payroll_expense other_expense
  ].freeze
  NORMAL_BALANCES = %w[debit credit].freeze

  validates :account_number, presence: true, uniqueness: { scope: :company_id }
  validates :name, presence: true
  validates :account_type, presence: true, inclusion: { in: TYPES }
  validates :sub_type, inclusion: { in: SUB_TYPES }, allow_blank: true
  validates :normal_balance, presence: true, inclusion: { in: NORMAL_BALANCES }

  scope :active, -> { where(is_active: true) }
  scope :postable, -> { where(is_header: false, is_active: true) }
  scope :roots, -> { where(parent_id: nil) }
  scope :by_type, ->(type) { where(account_type: type) }
  scope :ordered, -> { order(:account_number) }

  before_validation :set_normal_balance, on: :create

  def set_normal_balance
    return if normal_balance.present?
    self.normal_balance = case account_type
                          when 'asset', 'expense' then 'debit'
                          when 'liability', 'equity', 'revenue' then 'credit'
                          end
  end

  def self.tree_for_company(company)
    accounts = company.chart_of_accounts.ordered.to_a
    roots = accounts.select { |a| a.parent_id.nil? }
    roots.map { |root| build_node(root, accounts) }
  end

  def self.build_node(account, all_accounts)
    children = all_accounts.select { |a| a.parent_id == account.id }
    {
      id: account.id,
      account_number: account.account_number,
      name: account.name,
      description: account.description,
      account_type: account.account_type,
      sub_type: account.sub_type,
      normal_balance: account.normal_balance,
      is_header: account.is_header,
      is_active: account.is_active,
      is_system: account.is_system,
      parent_id: account.parent_id,
      position: account.position,
      bank_account_id: account.bank_account_id,
      children: children.map { |c| build_node(c, all_accounts) }
    }
  end

  def has_transactions?
    journal_entry_lines.exists?
  end

  def destroyable?
    !is_system && !has_transactions?
  end
end

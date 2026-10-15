# frozen_string_literal: true

# Bills for project cost lines (E68).
#
# Cost lines are job costing: by default they never reach the books, and a
# vendor's bill is entered in Accounting on its own, so nothing is counted
# twice. A company that turns on "cost lines post through bills" gets a draft
# bill for each cost line it enters with a vendor instead. The draft posts when
# someone approves it, like any bill.
class ProjectCostBillService
  SETTING_KEY = 'cost_lines_post_via_bills'

  # Expense accounts tried in order when the vendor has no default account.
  ACCOUNT_NAME_HINTS = ['Delivery & Setup', 'Subcontract', 'Setup', 'Install'].freeze

  def self.enabled?(company)
    settings = Setting.get('company', company.id, 'project_management')
    settings = settings.stringify_keys if settings.respond_to?(:stringify_keys)
    settings.is_a?(Hash) && ActiveModel::Type::Boolean.new.cast(settings[SETTING_KEY]) == true
  rescue StandardError
    false
  end

  # The vendor's own default expense account, else the first job-cost account
  # found by name. nil when the company has none of them.
  def self.expense_account_for(company, vendor)
    accounts = company.chart_of_accounts.where(is_active: true, is_header: false, account_type: 'expense')
    default_id = vendor&.default_expense_account_id
    return accounts.find_by(id: default_id) if default_id && accounts.exists?(id: default_id)

    ACCOUNT_NAME_HINTS.each do |hint|
      found = accounts.where('name ILIKE ?', "%#{hint}%").order(:account_number).first
      return found if found
    end
    nil
  end

  # Draft bill for a dealer-entered cost line, when the setting is on.
  def self.bill_cost_line!(item, user:)
    return unless enabled?(item.company)
    return if item.vendor_id.blank? || item.bill_id.present? || item.amount.to_d <= 0

    account = expense_account_for(item.company, item.vendor)
    project = item.project
    memo = [item.description, project.name].compact_blank.join(', ')
    bill = item.company.bills.create!(
      vendor_id: item.vendor_id,
      vendor_name: item.vendor&.name,
      project: project,
      location_id: project.location_id,
      status: 'draft',
      source: 'project_cost_line',
      bill_date: item.date || Date.current,
      reference_number: item.invoice_number.presence,
      memo: memo,
      created_by: user,
      submission: { 'cost_item_id' => item.id, 'needs_account' => account.nil? },
      bill_line_items_attributes: account ? [{ chart_of_account_id: account.id, amount: item.amount, description: memo.truncate(250) }] : []
    )
    item.update!(bill_id: bill.id)
    bill
  end

  # A draft bill made from a cost line follows that line's amount until it is
  # approved. After that the bill is the record and the line follows it.
  def self.follow_cost_line!(item)
    bill = item.bill
    return unless bill&.status == 'draft' && bill.source == 'project_cost_line'

    line = bill.bill_line_items.first
    return unless line && bill.bill_line_items.size == 1 && line.amount.to_d != item.amount.to_d

    line.update!(amount: item.amount)
    bill.save!
  end
end

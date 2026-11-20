# frozen_string_literal: true

# Costs typed on a project's Costs & Budget tab, and what each one does in the
# books (E109). The person picks how it was paid:
#
#   bill  - not paid yet. A draft bill for the vendor, approved in Accounting
#           or from the cost list; the line follows the bill.
#   paid  - already paid. Records the expense now (job cost up, the bank or
#           card down), the same entry Record Expense makes, and the line is
#           Paid and linked to it. No bill, no approval step.
#   track - tracking only. Counts on the job, never reaches the books.
#
# Bills and expenses are only made when the company has "cost lines post
# through bills" on; otherwise every typed line is tracking only, so a company
# that keeps its books elsewhere never gets entries it did not ask for.
#
# A line's status comes from its bill or its entry, so it can't be marked
# Approved or Paid by hand once either exists.
class ProjectCostEntryService
  class Error < StandardError; end

  PAY_MODES = %w[bill paid track].freeze

  def initialize(project, user:)
    @project = project
    @company = project.company
    @user = user
  end

  def self.posting_on?(company)
    ProjectCostBillService.enabled?(company)
  end

  # How the line is paid, from what it is linked to.
  def self.pay_mode_for(item)
    return 'bill' if item.bill_id.present?
    return 'paid' if item.journal_entry_id.present?

    'track'
  end

  # Where a line came from, in words for the cost list.
  def self.source_for(item)
    source = item.metadata.to_h['source']
    bill = item.bill
    if bill
      return 'Contractor portal invoice' if bill.source.to_s.include?('portal')
      return 'Typed on the project, draft bill' if bill.source == 'project_cost_line'
      return 'Linked installer bill' if bill.source.to_s.include?('installer')

      return 'Bill entered in Accounting'
    end
    if item.journal_entry_id
      return 'Bank feed' if source == 'auto'
      return 'Already paid, expense' if source == 'quick_entry'

      return 'Journal entry'
    end
    return 'Bid award' if item.description.to_s.start_with?('Bid:')
    return 'Linked installer job, committed' if source == 'project_link'
    return 'Installer change order, committed' if source.to_s.include?('link_change')

    'Tracking only'
  end

  # Builds and saves a new line. attrs are the permitted cost item params.
  def create!(attrs, pay_mode:, payment_account_id: nil, category_account_id: nil)
    pay_mode = pay_mode.presence || default_mode(attrs)
    raise Error, 'Pick how this was paid' unless PAY_MODES.include?(pay_mode)

    if pay_mode != 'track' && !self.class.posting_on?(@company)
      raise Error, 'Costs on projects are tracking only for this company. Enter the bill or expense in Accounting.'
    end

    item = @project.project_cost_items.build(attrs.except(:status, :paid_at, :approved_by_id))
    item.company_id = @company.id
    item.metadata = (item.metadata || {}).to_h.deep_stringify_keys.merge('pay_mode' => pay_mode)

    case pay_mode
    when 'bill'
      raise Error, 'Pick the vendor this is owed to, so the bill has someone to pay' if item.vendor_id.blank?
      raise Error, 'Enter an amount over zero' unless item.amount.to_d.positive?

      item.status = 'pending'
      ActiveRecord::Base.transaction do
        item.save!
        ProjectCostBillService.bill_cost_line!(item, user: @user)
      end
    when 'paid'
      record_paid!(item, payment_account_id: payment_account_id, category_account_id: category_account_id)
    else
      item.status = attrs[:status].presence_in(%w[pending approved]) || 'approved'
      item.save!
    end
    item.reload
  end

  # Approves the draft bill behind a line, which posts it (job cost and
  # Accounts Payable). The same thing Post does in Accounting, Bills.
  def approve!(item)
    bill = item.bill
    raise Error, 'This cost has no bill to approve' unless bill
    raise Error, "Bill #{bill.bill_number} is already approved" unless bill.status == 'draft'
    if bill.bill_line_items.empty?
      raise Error, "Bill #{bill.bill_number} needs an expense account before it can be approved. Open it in Accounting, Bills."
    end

    ActiveRecord::Base.transaction do
      bill.update!(status: 'pending')
      bill.send(:auto_post_bill_je) if bill.journal_entry_id.nil?
    end
    item.reload
  end

  # Removes a line. A draft bill it made goes with it; anything already in
  # the books has to be undone where it was recorded.
  def remove!(item)
    if (bill = item.bill)
      if bill.status == 'draft' && bill.source == 'project_cost_line'
        ActiveRecord::Base.transaction do
          bill.update!(is_deleted: true, journal_entry_id: nil)
          item.update!(is_deleted: true)
        end
        return item
      end
      raise Error, "This cost is on bill #{bill.bill_number}. Void or delete the bill in Accounting, Bills, and the cost goes with it."
    end
    if (je = item.journal_entry)
      where = item.metadata.to_h['source'] == 'auto' ? 'unmatch the bank line in Accounting, Banking' : "void entry #{je.entry_number} in Accounting"
      raise Error, "This cost is already in your books. To remove it, #{where}."
    end

    item.update!(is_deleted: true)
    item
  end

  # Lines already on the job from the same vendor for the same amount: typing
  # it again would count it twice.
  def duplicates(vendor_id:, amount:, except_id: nil)
    return [] if vendor_id.blank? || amount.to_d <= 0

    @project.project_cost_items.not_deleted
            .where(vendor_id: vendor_id, amount: amount.to_d)
            .where.not(id: except_id)
            .includes(:bill).order(:created_at).limit(5).to_a
  end

  private

  def default_mode(attrs)
    self.class.posting_on?(@company) && attrs[:contractor_id].present? ? 'bill' : 'track'
  end

  def record_paid!(item, payment_account_id:, category_account_id:)
    raise Error, 'Enter an amount over zero' unless item.amount.to_d.positive?

    bank = @company.bank_accounts.find_by(chart_of_account_id: payment_account_id) if payment_account_id.present?
    raise Error, 'Pick the bank account or card it was paid from' unless bank&.chart_of_account_id

    category = if category_account_id.present?
                 @company.chart_of_accounts.postable.where(account_type: 'expense').find_by(id: category_account_id)
               else
                 ProjectCostBillService.expense_account_for(@company, item.vendor)
               end
    raise Error, 'Pick the expense account this goes to' unless category

    item.status = 'paid'
    item.paid_at = Time.current
    item.date ||= Date.current
    vendor = item.vendor
    memo = [vendor&.name || item.vendor_name, item.description].compact_blank.join(', ').truncate(250)
    tags = { project_id: @project.id, deal_id: @project.deal_id }

    ActiveRecord::Base.transaction do
      item.save!
      je = @company.journal_entries.build(
        entry_date: item.date, memo: memo, source_type: 'quick_entry', posted_by: @user
      )
      je.job_cost_vendor = vendor
      je.job_cost_phase_id = item.project_phase_id
      je.job_cost_description = item.description
      je.job_cost_item = item
      location_id = @project.location_id || Current.location_id
      je.journal_entry_lines.build(chart_of_account: category, debit_amount: item.amount, credit_amount: 0,
                                   memo: memo, location_id: location_id, **tags)
      je.journal_entry_lines.build(chart_of_account_id: bank.chart_of_account_id, debit_amount: 0,
                                   credit_amount: item.amount, memo: memo, location_id: location_id)
      je.save!
    end
  rescue ActiveRecord::RecordInvalid => e
    raise Error, e.record.errors.full_messages.to_sentence
  end
end

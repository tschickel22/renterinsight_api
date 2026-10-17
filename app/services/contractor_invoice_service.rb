# frozen_string_literal: true

# A contractor's invoice, uploaded in the portal, becomes a draft bill for the
# dealer (E68 step 2).
#
# The bill stays a draft until the dealer approves it, so nothing reaches the
# books on the contractor's word alone. It is linked to the project, and to the
# project cost line it pays for: an open cost line already entered for this
# contractor on this phase is matched rather than duplicated, so the job cost
# counts the work once.
class ContractorInvoiceService
  class Error < StandardError; end

  attr_reader :bill, :cost_item

  def initialize(contractor:, project:, phase: nil, assignment: nil)
    @contractor = contractor
    @project = project
    @company = project.company
    @phase = phase
    @assignment = assignment
    raise Error, 'Contractor does not work for this company' unless contractor.company_id == @company.id
  end

  # amount is the contractor's own total and is required. The AI scan only
  # fills in what they left blank (number, dates) and records what it read so
  # the dealer can see when the document disagrees with the typed total.
  def submit!(file:, amount:, invoice_number: nil, invoice_date: nil, notes: nil)
    amount = amount.to_s.delete(',$').to_d
    raise Error, 'Enter the invoice total' unless amount.positive?
    raise Error, 'Attach the invoice' if file.blank?

    scan = scan_document(file)
    invoice_number = invoice_number.presence || scan&.dig(:reference_number)
    check_duplicate!(invoice_number)

    stored = PrivateFiles.upload(file, folder: "bills/#{@company.id}/contractor-invoices")
    attachment = {
      'url' => stored[:ref],
      's3_key' => stored[:key],
      'filename' => file.original_filename,
      'size' => stored[:size],
      'content_type' => stored[:content_type],
      'uploaded_at' => Time.current.iso8601,
      'uploaded_by_contractor_id' => @contractor.id
    }

    ActiveRecord::Base.transaction do
      @bill = create_bill!(amount, invoice_number, invoice_date, notes, scan, attachment)
      @cost_item = link_cost_item!(amount, invoice_number, stored[:ref])
    end

    ProjectNotificationService.announce_invoice_submitted(@bill, @contractor, @project)
    @bill
  end

  private

  def scan_document(file)
    result = Accounting::BillScanService.new(@company).scan(file)
    file.rewind if file.respond_to?(:rewind)
    result
  rescue Accounting::BillScanService::ScanError, StandardError => e
    Rails.logger.info("[ContractorInvoice] scan skipped: #{e.message}")
    file.rewind if file.respond_to?(:rewind)
    nil
  end

  def check_duplicate!(invoice_number)
    return if invoice_number.blank?

    dup = @company.bills.where(vendor_id: @contractor.id, reference_number: invoice_number, is_deleted: false)
                  .where.not(status: 'void').exists?
    raise Error, "Invoice #{invoice_number} was already submitted" if dup
  end

  def create_bill!(amount, invoice_number, invoice_date, notes, scan, attachment)
    account = ProjectCostBillService.expense_account_for(@company, @contractor)
    where = @phase ? "#{@phase.name}, #{@project.name}" : @project.name
    memo = ["Invoice from #{@contractor.name} for #{where}", notes.presence].compact.join(". ")

    @company.bills.create!(
      vendor: @contractor,
      vendor_name: @contractor.name,
      project: @project,
      location_id: @project.location_id,
      status: 'draft',
      source: 'contractor_portal',
      bill_date: parse_date(invoice_date) || parse_date(scan&.dig(:bill_date)) || Date.current,
      due_date: parse_date(scan&.dig(:due_date)),
      reference_number: invoice_number,
      memo: memo,
      attachments: [attachment],
      submission: {
        'contractor_id' => @contractor.id,
        'assignment_id' => @assignment&.id,
        'phase_id' => @phase&.id,
        'amount' => amount.to_s,
        'invoice_number' => invoice_number,
        'notes' => notes,
        'scanned_total' => scan&.dig(:total_amount),
        'needs_account' => account.nil?
      }.compact,
      # Without an expense account the line cannot exist (the column is
      # required). The draft then shows a zero total and needs_account, and
      # the dealer picks the account when approving.
      bill_line_items_attributes: account ? [{ chart_of_account_id: account.id, amount: amount, description: memo.truncate(250) }] : []
    )
  end

  # An open cost line already entered for this contractor on this phase is the
  # one the invoice pays for. Only an unambiguous match is used; otherwise the
  # invoice gets a cost line of its own.
  #
  # "Open" includes a line whose only bill is the unposted draft the
  # cost-lines-post-via-bills setting made for it: the contractor's invoice
  # replaces that draft, or the cost would be billed twice.
  def link_cost_item!(amount, invoice_number, receipt_ref)
    open_lines = @project.project_cost_items.not_deleted
                         .where(vendor_id: @contractor.id, status: 'pending', project_phase_id: @phase&.id)
                         .where.not(id: @bill.project_cost_items.select(:id))
                         .includes(:bill).to_a
                         .select { |l| l.bill.nil? || replaceable_draft?(l.bill) }
                         .first(2)

    if open_lines.size == 1
      line = open_lines.first
      placeholder = line.bill
      line.update!(
        bill_id: @bill.id,
        invoice_number: invoice_number.presence || line.invoice_number,
        receipt_url: receipt_ref,
        metadata: (line.metadata || {}).merge('amount_before_invoice' => line.amount.to_s).deep_stringify_keys,
        amount: amount
      )
      placeholder&.destroy!
      return line
    end

    @project.project_cost_items.create!(
      company_id: @company.id,
      project_phase_id: @phase&.id,
      vendor_id: @contractor.id,
      cost_type: 'subcontractor',
      description: "Invoice from #{@contractor.name}",
      invoice_number: invoice_number,
      amount: amount,
      date: @bill.bill_date,
      status: 'pending',
      receipt_url: receipt_ref,
      bill_id: @bill.id,
      metadata: { 'source' => 'contractor_portal' }
    )
  end

  # A draft made from a cost line has never posted and carries nothing but
  # that line's amount, so it can go.
  def replaceable_draft?(bill)
    bill.status == 'draft' && bill.source == 'project_cost_line' && bill.journal_entry_id.nil? &&
      bill.bill_payments.none?
  end

  def parse_date(value)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue Date::Error
    nil
  end
end

# frozen_string_literal: true

# E99: what a bank feed deposit could be a payment on. Deals still owed money
# (their next draw and what is owed, from Reports::DrawProgress) and other
# open invoices, a project's own invoice to the dealer among them. Ones whose
# next draw, amount owed or amount due equals the deposit come first, marked
# exact, so a lender's draw lines up with the deal it was for.
class BankFeedPaymentOptions
  LIMIT = 8
  TOLERANCE = BigDecimal('0.01')

  def initialize(company, transaction, search: nil)
    @company = company
    @txn = transaction
    @amount = transaction.amount.to_d.abs
    @search = search.to_s.strip.presence
  end

  def call
    { amount: @amount.to_f, deals: deals, invoices: invoices }
  end

  private

  def exact?(value)
    value && (value.to_d - @amount).abs <= TOLERANCE
  end

  def deals
    scope = @company.deals.where(deleted_at: nil)
    if @search
      term = "%#{@search}%"
      scope = scope.left_joins(:contact).where(
        'deals.deal_number ILIKE :t OR deals.name ILIKE :t OR contacts.first_name ILIKE :t OR contacts.last_name ILIKE :t ' \
        "OR (contacts.first_name || ' ' || contacts.last_name) ILIKE :t", t: term
      )
    end
    candidates = scope.includes(:contact).order(updated_at: :desc).limit(200).to_a
    invoices = @company.invoices.where(id: candidates.map(&:deal_invoice_id).compact).index_by(&:id)
    projects = @company.projects.not_deleted.where(deal_id: candidates.map(&:id)).pluck(:deal_id, :id, :name)
                       .each_with_object({}) { |(deal_id, id, name), h| h[deal_id] ||= { id: id, name: name } }

    rows = candidates.filter_map do |deal|
      next if deal.stage_is_lost?

      invoice = invoices[deal.deal_invoice_id]
      approved = deal.gl_posted_at.present?
      owed = invoice&.amount_due&.to_d
      next if approved && invoice && !owed.positive?
      # Deposits on deals not yet approved, and approved deals that never got
      # an invoice (one is made when the payment is applied), only when searched for.
      next if !@search && (!approved || invoice.nil?)

      next_draw = invoice && Reports::DrawProgress.call(invoice).find { |d| d[:status] != 'paid' }
      {
        id: deal.id, deal_number: deal.deal_number, name: deal.name, customer_name: deal.customer_display_name,
        approved: approved, owed: owed&.to_f,
        next_draw: next_draw && { description: next_draw[:description], balance: next_draw[:balance].to_f,
                                  due_date: next_draw[:due_date], lender: next_draw[:lender] },
        project: projects[deal.id],
        takes: approved ? 'payment' : 'deposit',
        exact: exact?(next_draw&.dig(:balance)) || exact?(owed)
      }
    end
    rows.sort_by { |r| [r[:exact] ? 0 : 1] }.first(LIMIT)
  end

  def invoices
    scope = @company.invoices.not_deleted.where('amount_due > 0').where.not(status: %w[draft cancelled paid])
                    .where.not(source_type: 'deal_close')
    if @search
      term = "%#{@search}%"
      scope = scope.left_joins(:contact).where(
        "invoices.invoice_number ILIKE :t OR contacts.first_name ILIKE :t OR contacts.last_name ILIKE :t", t: term
      )
    end
    rows = scope.includes(:contact, :recipient).order(due_date: :asc).limit(100).map do |inv|
      project = inv.source_type == 'Project' ? @company.projects.find_by(id: inv.source_id) : nil
      {
        id: inv.id, invoice_number: inv.invoice_number, due_date: inv.due_date, amount_due: inv.amount_due.to_f,
        total: inv.total.to_f,
        customer_name: inv.recipient.try(:name).presence || inv.recipient.try(:full_name).presence || inv.contact&.full_name,
        project: project && { id: project.id, name: project.name },
        exact: exact?(inv.amount_due)
      }
    end
    rows.sort_by { |r| [r[:exact] ? 0 : 1] }.first(LIMIT)
  end
end

# frozen_string_literal: true

# Creates and syncs the AR invoice that backs a closed deal.
#
# Called after a deal is GL-approved. The invoice mirrors the deal's selling price
# plus tax and add-on fees, and optionally attaches a draw schedule derived from
# the location's (or company's) default DrawScheduleTemplate so the cash flow
# forecast and portal payment UI can track draws independently.
class DealInvoiceService
  # Effective fee accessors on Deal source from `category:fee` line items when present
  # (Phase 3), falling back to the deprecated columns for legacy/API deals. Mirrors the
  # original column set: setup + delivery + skirting + doc (accessories NOT billed here).
  ADDON_FEE_METHODS = %i[effective_setup_fee effective_delivery_fee effective_skirting_fee effective_doc_fee].freeze

  def initialize(deal, user: nil)
    @deal = deal
    @user = user
    @company = deal.company
  end

  PLAN_TYPES = %w[single draws financed].freeze

  # Returns the existing invoice if already created; otherwise builds one.
  # Idempotent: safe to call repeatedly from the approve action.
  #
  # plan (from the approval screen; nil keeps the default: the location's or
  # company's default draw template, none for a cash deal):
  #   { type: 'single', due_date: }                    one payment, no draws
  #   { type: 'draws', template_id: }                  that draw template
  #   { type: 'financed', lender_amount:, lender_due_date: }
  #       the customer's share due at close, then the lender's funding as its
  #       own draw on the same invoice
  #
  # Deposits already taken on the deal are applied to the new invoice.
  def create_invoice!(plan: nil)
    existing = existing_invoice
    return existing if existing

    base_date = resolve_base_date
    total = calculate_total
    schedule = plan.present? ? schedule_for_plan(plan, total, base_date) : build_schedule(resolve_template, total, base_date)
    single_due = plan.present? && plan[:type].to_s == 'single' ? (parse_date(plan[:due_date]) || base_date) : nil

    invoice = nil

    Invoice.transaction do
      invoice = Invoice.new(
        company: @company,
        contact: @deal.contact,
        deal: @deal,
        location: @deal.location,
        invoice_date: base_date,
        due_date: schedule_last_due_date(schedule) || single_due || (base_date + 30.days),
        status: 'sent',
        source_type: 'deal_close',
        source: @deal,
        billing_category: 'home_sale',
        notes: 'Auto-generated from deal close',
        sales_rep: @user
      )

      invoice.draw_schedule = schedule if schedule
      invoice.invoice_items.build(
        description: invoice_line_description,
        quantity: 1,
        rate: total,
        amount: total,
        position: 1
      )

      invoice.save!

      @deal.update_columns(deal_invoice_id: invoice.id)
    end

    apply_deposits!(invoice)
    invoice
  end

  # Money taken on the deal before it had an invoice, applied to it oldest
  # first. Returns the total applied.
  def apply_deposits!(invoice)
    applied = 0.to_d
    @company.cash_receipts.posted.not_deleted.where(deal_id: @deal.id).where('amount_unapplied > 0')
            .order(:receipt_date, :id).each do |receipt|
      break unless invoice.reload.amount_due.to_d.positive?

      app = receipt.apply_deposit_to!(invoice, receipt.amount_unapplied, user: @user)
      applied += app.amount_applied.to_d if app
    end
    applied
  end

  # Fills an invoice's draws in order with everything paid or credited on it,
  # so the stored schedule matches the invoice whichever way the money came in
  # (deal payment, deposit, portal, card).
  def self.refresh_draws!(invoice)
    schedule = invoice.draw_schedule
    return unless schedule.is_a?(Hash) && schedule['draws'].is_a?(Array) && schedule['draws'].any?

    schedule = schedule.deep_dup
    left = invoice.amount_paid.to_d + invoice.amount_credited.to_d
    schedule['draws'].sort_by { |d| d['position'].to_i }.each do |draw|
      amount = draw['amount'].to_d
      paid = [left, amount].min
      left -= paid
      draw['paid_amount'] = paid.round(2).to_f
      draw['status'] = if amount - paid <= BigDecimal('0.001') then 'paid'
                       elsif paid.positive? then 'partial'
                       else 'pending'
                       end
    end
    invoice.update_column(:draw_schedule, schedule) if schedule != invoice.draw_schedule
  end

  # The pieces the invoice will bill, for the approval screen to show the
  # total with the tax it is about to post.
  def total_parts
    base = (@deal.try(:selling_price) || 0).to_d
    used_products_total = base.zero?
    base = (@deal.try(:calculated_value) || @deal.try(:value) || 0).to_d if used_products_total
    fees = used_products_total ? 0.to_d : ADDON_FEE_METHODS.sum { |m| (@deal.try(m) || 0).to_d }
    # Everything billed besides the price: other line items when the books
    # carry them, else the fee types.
    fees = booked_receivable - base if booked_receivable
    tax = calculate_total - base - fees
    # Before approval nothing is posted yet: show the tax approval will post.
    unless tax.positive? || @deal.gl_posted_at.present?
      tax = Accounting::DealAccountingService.new(@deal).sales_tax_lines.sum { |l| l[:credit_amount].to_d }
    end
    { base: base.round(2).to_f, fees: fees.round(2).to_f, tax: tax.round(2).to_f }
  end

  # The plan the approval screen starts from.
  def default_plan
    type = @deal.try(:payment_type).to_s
    financed = (@deal.try(:financed_amount) || 0).to_d
    if %w[financed cash_and_finance].include?(type) && financed.positive?
      { type: 'financed', lender_amount: financed.to_f, lender_due_date: (resolve_base_date + 30.days).iso8601 }
    elsif type != 'cash' && (template = resolve_template)
      { type: 'draws', template_id: template.id }
    else
      { type: 'single', due_date: resolve_base_date.iso8601 }
    end
  end

  # Recalculate totals and refresh unpaid draw amounts. Already-paid draws keep
  # their amount and status; the next draw absorbs any rounding drift.
  def sync_invoice!(invoice)
    total = calculate_total

    Invoice.transaction do
      invoice.invoice_items.destroy_all
      invoice.invoice_items.create!(
        description: invoice_line_description,
        quantity: 1,
        rate: total,
        amount: total,
        position: 1
      )

      if invoice.draw_schedule.present? && invoice.draw_schedule['draws'].is_a?(Array)
        invoice.draw_schedule = recompute_unpaid_draws(invoice.draw_schedule, total)
      end

      invoice.save!
    end

    invoice
  end

  # What the deal's invoice bills (price, posted tax and fees), for a deal
  # that has no invoice yet.
  def deal_total
    calculate_total
  end

  private

  def parse_date(value)
    value.is_a?(Date) ? value : Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def schedule_for_plan(plan, total, base_date)
    case plan[:type].to_s
    when 'draws'
      template = @company.draw_schedule_templates.active.find_by(id: plan[:template_id])
      raise ArgumentError, 'Pick a draw schedule' unless template

      build_schedule(template, total, base_date, force: true)
    when 'financed'
      lender = [plan[:lender_amount].to_d, total.to_d].min.round(2)
      raise ArgumentError, 'Enter what the lender is funding' unless lender.positive?

      lender_due = parse_date(plan[:lender_due_date]) || (base_date + 30.days)
      down = (total.to_d - lender).round(2)
      lender_name = @deal.try(:lender_name).presence
      draws = []
      draws << plan_draw(1, 'Down payment', down, total, base_date).merge('kind' => 'down_payment') if down.positive?
      draws << plan_draw(draws.size + 1, ['Lender funding', lender_name].compact.join(', '), lender, total, lender_due).merge('kind' => 'lender')
      { 'plan' => 'financed', 'total_amount' => total.to_f, 'base_date' => base_date.iso8601, 'draws' => draws }
    else
      nil
    end
  end

  def plan_draw(position, description, amount, total, due)
    {
      'position' => position, 'description' => description, 'amount' => amount.to_f,
      'percentage' => total.to_d.positive? ? (amount / total.to_d * 100).round(4).to_f : 0,
      'due_date' => due.iso8601, 'days_after_close' => 0, 'status' => 'pending', 'paid_amount' => 0.0
    }
  end

  def existing_invoice
    return nil if @deal.deal_invoice_id.blank?
    @company.invoices.find_by(id: @deal.deal_invoice_id)
  end

  def resolve_template
    location_default = DrawScheduleTemplate
      .where(company_id: @company.id, location_id: @deal.location_id, is_default: true)
      .active
      .first
    return location_default if location_default

    @company.draw_schedule_templates
      .active
      .where(is_default: true, location_id: nil)
      .first
  end

  def resolve_base_date
    @deal.try(:actual_close_date) || @deal.try(:expected_close_date) || Date.current
  end

  def calculate_total
    # `selling_price` is the home-line-item price only; deals without a typed home
    # line item leave it at 0 even when `value` (line-items total) is non-zero.
    # Fall back to `calculated_value`, which already prefers products → selling_price → value.
    base = (@deal.try(:selling_price) || 0).to_d
    used_products_total = base.zero?
    base = (@deal.try(:calculated_value) || @deal.try(:value) || 0).to_d if used_products_total
    # Sales tax posted at approval lands in total_tax_amount; tax_amount is the
    # deal sheet's figure and is often 0, not nil, which used to leave the
    # posted tax off the invoice while the ledger billed it.
    posted_tax = (@deal.try(:total_tax_amount) || 0).to_d
    tax_amount = posted_tax.positive? ? posted_tax : (@deal.try(:tax_amount) || 0).to_d
    # The invoice bills what approval books as owed: the price and every other
    # line item on the deal (accessories, fees, F&I products), so the invoice
    # and the books agree. It used to add only four fee types, and a $5,000 F&I
    # product on staging's D-000042 was owed on the books but not invoiced.
    booked = booked_receivable
    return (booked + tax_amount).round(2) if booked

    # Add fees ONLY when base is the home price. When we fell back to calculated_value
    # (= sum of ALL deal_products, which already includes the category:fee line items),
    # adding them again would double-count the fees.
    addons = used_products_total ? 0.to_d : ADDON_FEE_METHODS.sum { |m| (@deal.try(m) || 0).to_d }
    (base + tax_amount + addons).round(2)
  end

  # What the closing entry debits to receivables (before sales tax, which
  # posts separately), or nil when it books none (no AR account set up).
  def booked_receivable
    return @booked_receivable if defined?(@booked_receivable)

    ar = AccountingSettings.for_company(@company).default_ar_account
    @booked_receivable = if ar
                           lines = Accounting::DealAccountingService.new(@deal).closing_lines
                           sum = lines.select { |l| l[:chart_of_account_id] == ar.id }
                                      .sum { |l| l[:debit_amount].to_d - l[:credit_amount].to_d }
                           sum.positive? ? sum : nil
                         end
  rescue => e
    Rails.logger.warn("[DealInvoiceService] Booked receivable failed for deal #{@deal.id}: #{e.message}")
    @booked_receivable = nil
  end

  def build_schedule(template, total, base_date, force: false)
    return nil unless template
    return nil if !force && @deal.try(:payment_type).to_s == 'cash'

    # Mirror calculate_total's fallback — without it, the schedule applies percentages
    # against $0 when the deal has no typed home line item.
    home_price = (@deal.try(:selling_price) || 0).to_f
    home_price = (@deal.try(:calculated_value) || @deal.try(:value) || 0).to_f if home_price.zero?
    template.to_invoice_schedule_with_dates(
      total.to_f,
      base_date: base_date,
      delivery_date: @deal.try(:delivery_date),
      home_price: home_price
    )
  end

  def schedule_last_due_date(schedule)
    return nil unless schedule.is_a?(Hash)
    draws = schedule['draws'] || schedule[:draws]
    return nil unless draws.is_a?(Array) && draws.any?
    dates = draws.map { |d| d['due_date'] || d[:due_date] }.compact
    return nil if dates.empty?
    Date.parse(dates.max)
  rescue ArgumentError, TypeError
    nil
  end

  def invoice_line_description
    vehicle = @deal.try(:vehicle)
    if vehicle
      label = [vehicle.try(:year), vehicle.try(:make), vehicle.try(:model)].compact.join(' ')
      return label.presence || @deal.try(:name) || "Deal #{@deal.deal_number}"
    end
    @deal.try(:name) || "Deal #{@deal.deal_number || @deal.id}"
  end

  # Rebuild unpaid draw amounts proportionally to the new total while preserving
  # paid draws verbatim. Any rounding remainder lands on the last unpaid draw.
  def recompute_unpaid_draws(schedule, new_total)
    schedule = schedule.deep_dup
    draws = Array(schedule['draws'])

    paid_total = draws
      .select { |d| draw_paid?(d) }
      .sum { |d| (d['amount'] || 0).to_f }

    remaining_total = (new_total.to_f - paid_total).round(2)
    unpaid = draws.reject { |d| draw_paid?(d) }
    pct_sum = unpaid.sum { |d| (d['percentage'] || 0).to_f }

    if pct_sum > 0
      running = 0.0
      unpaid.each_with_index do |draw, idx|
        pct = (draw['percentage'] || 0).to_f
        amt = if idx == unpaid.length - 1
                (remaining_total - running).round(2)
              else
                share = (remaining_total * pct / pct_sum).round(2)
                running += share
                share
              end
        draw['amount'] = amt
      end
    end

    schedule['total_amount'] = new_total.to_f
    schedule['draws'] = draws
    schedule
  end

  def draw_paid?(draw)
    %w[paid partial].include?(draw['status'].to_s) || (draw['paid_amount'] || 0).to_f > 0
  end
end

# frozen_string_literal: true

# Creates and syncs the AR invoice that backs a closed deal.
#
# Called after a deal is GL-approved. The invoice mirrors the deal's selling price
# plus tax and add-on fees, and optionally attaches a draw schedule derived from
# the location's (or company's) default DrawScheduleTemplate so the cash flow
# forecast and portal payment UI can track draws independently.
class DealInvoiceService
  ADDON_FIELDS = %i[setup_fee delivery_fee skirting_fee doc_fee].freeze

  def initialize(deal, user: nil)
    @deal = deal
    @user = user
    @company = deal.company
  end

  # Returns the existing invoice if already created; otherwise builds one.
  # Idempotent: safe to call repeatedly from the approve action.
  def create_invoice!
    existing = existing_invoice
    return existing if existing

    template = resolve_template
    base_date = resolve_base_date
    total = calculate_total
    schedule = build_schedule(template, total, base_date)

    invoice = nil

    Invoice.transaction do
      invoice = Invoice.new(
        company: @company,
        contact: @deal.contact,
        deal: @deal,
        location: @deal.location,
        invoice_date: base_date,
        due_date: schedule_last_due_date(schedule) || (base_date + 30.days),
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

    invoice
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

  private

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
    base = (@deal.try(:calculated_value) || @deal.try(:value) || 0).to_d if base.zero?
    tax_amount = (@deal.try(:tax_amount) || @deal.try(:total_tax_amount) || 0).to_d
    addons = ADDON_FIELDS.sum { |f| (@deal.try(f) || 0).to_d }
    (base + tax_amount + addons).round(2)
  end

  def build_schedule(template, total, base_date)
    return nil unless template
    return nil if @deal.try(:payment_type).to_s == 'cash'

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

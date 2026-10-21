# frozen_string_literal: true

# How a rate card, and a job's price and change orders, read on either side
# of a company link (E68 step 6). Both companies see the same figures: they
# are the prices between them, not either company's own costs.
module LinkPricingJson
  extend ActiveSupport::Concern

  private

  def rate_card_json(card)
    return nil unless card

    {
      id: card.id, version: card.version, status: card.status, note: card.note,
      items: card.items.map { |i| i.slice('key', 'name', 'kind', 'unit').merge('price' => i['price'].to_f) },
      submitted_at: card.created_at, decided_at: card.decided_at, decline_reason: card.decline_reason
    }
  end

  def link_change_json(change)
    {
      id: change.id, number: change.number, kind: change.kind, label: change.label, status: change.status,
      amount: change.amount.to_f, description: change.description, lines: price_lines_json(change.lines),
      dealer_phase_id: change.dealer_phase_id, phase_name: change.dealer_phase&.name,
      requested_at: change.created_at, decided_at: change.decided_at, decline_reason: change.decline_reason
    }
  end

  # The job's price: where it came from, its lines, the approved total and
  # every request on it, newest first.
  def link_price_json(pl)
    changes = pl.link_changes.includes(:dealer_phase).order(number: :desc).to_a
    {
      price_source: pl.price_source, price_lines: price_lines_json(pl.price_lines),
      rate_card_version: pl.link_rate_card&.version,
      price_agreed: pl.price_agreed?, approved_total: pl.legacy_price? ? pl.fee_amount&.to_f : (pl.price_agreed? ? pl.approved_total.to_f : nil),
      changes: changes.map { |c| link_change_json(c) },
      pending_count: changes.count(&:pending?)
    }
  end

  def price_lines_json(lines)
    Array(lines).map do |l|
      { item_key: l['item_key'], name: l['name'], unit: l['unit'], qty: l['qty'].to_f, price: l['price'].to_f, amount: l['amount'].to_f }
    end
  end
end

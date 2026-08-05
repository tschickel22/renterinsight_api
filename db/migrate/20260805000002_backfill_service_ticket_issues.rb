# frozen_string_literal: true

# Lifts every existing ticket's flat parts/labor arrays into the new issue
# layer. A ticket whose line_item_billing mixes warranty and customer rows is
# split into two issues, since pay type now lives on the issue rather than
# being tagged per row.
#
# Existing amounts land in the *actual* fields, not the estimate fields: they
# are already on the books, and totals resolve actual-else-estimate, so every
# ticket's total is unchanged by this migration.
class BackfillServiceTicketIssues < ActiveRecord::Migration[8.0]
  disable_ddl_transaction!

  class MigrationTicket < ActiveRecord::Base
    self.table_name = 'service_tickets'
  end

  class MigrationIssue < ActiveRecord::Base
    self.table_name = 'service_ticket_issues'
  end

  def up
    # service_tickets.deleted_at exists in some databases and not others: it is
    # in schema.rb but no migration ever created it, so the deployed databases
    # don't have the column. Skip the filter where it's absent rather than
    # abort the deploy.
    scope = MigrationTicket.all
    scope = scope.where(deleted_at: nil) if MigrationTicket.column_names.include?('deleted_at')

    scope.find_each(batch_size: 200) do |ticket|
      next if MigrationIssue.exists?(service_ticket_id: ticket.id)

      parts = coerce_array(ticket.parts)
      labor = coerce_array(ticket.labor)
      billing = coerce_array(ticket.line_item_billing)

      default_pay = default_pay_type_for(ticket)
      grouped = group_rows(parts, labor, billing, default_pay)

      # A ticket with no line items still gets one issue, so the UI never has
      # to special-case an empty ticket.
      grouped = { default_pay => { parts: [], labor: [] } } if grouped.empty?

      grouped.each_with_index do |(pay_type, rows), index|
        MigrationIssue.create!(
          company_id: ticket.company_id,
          service_ticket_id: ticket.id,
          position: index,
          title: issue_title(ticket, pay_type, grouped.size),
          complaint: ticket.description,
          status: issue_status_for(ticket),
          pay_type: pay_type,
          manufacturer_id: manufacturer_for(billing, pay_type),
          visibility: ticket.dealer_only ? 'internal' : 'external',
          portal_visible: ticket.portal_visible.nil? ? true : ticket.portal_visible,
          authorization_status: 'not_required',
          pricing_status: pricing_status_for(ticket, rows),
          parts: rows[:parts],
          labor: rows[:labor],
          custom_field_values: {},
          created_at: ticket.created_at,
          updated_at: ticket.updated_at
        )
      end
    end
  end

  def down
    MigrationIssue.delete_all
  end

  private

  # Legacy rows are inconsistently encoded -- some hold a JSON array, some hold
  # a JSON string *containing* a JSON array (double-encoded by the model's
  # attribute cast writing an already-serialized value). Unwrap until an array
  # falls out.
  def coerce_array(value)
    current = value

    3.times do
      return current if current.is_a?(Array)
      return [] if current.blank?
      break unless current.is_a?(String)

      begin
        current = JSON.parse(current)
      rescue JSON::ParserError
        return []
      end
    end

    current.is_a?(Array) ? current : []
  end

  def default_pay_type_for(ticket)
    warranty = ticket.is_warranty_confirmed || ticket.is_warranty_suspected || ticket.warranty_claim_id.present?
    warranty ? 'warranty' : 'customer'
  end

  def issue_status_for(ticket)
    ticket.status.to_s == 'completed' ? 'complete' : 'open'
  end

  # The old schema had no way to say "not priced yet", so a ticket sent to a
  # vendor with all zeros is indistinguishable from one genuinely priced at
  # zero. Treat an all-zero issue as unpriced -- that is overwhelmingly what a
  # zeroed MH ticket meant.
  def pricing_status_for(ticket, rows)
    amounts = rows[:parts].map { |p| p['actQuantity'].to_f * p['actUnitCost'].to_f } +
              rows[:labor].map { |l| l['actHours'].to_f * l['actRate'].to_f }

    return 'unpriced' if amounts.empty? || amounts.all?(&:zero?)

    ticket.status.to_s == 'completed' ? 'final' : 'estimated'
  end

  # billing rows are {index, type, billing_type, manufacturer_id} keyed by
  # array position -- the fragile identity this migration retires.
  def billing_for(billing, index, type)
    row = billing.find do |b|
      b['index'].to_i == index && b['type'].to_s == type
    end
    row && row['billing_type'].to_s.presence
  end

  def manufacturer_for(billing, pay_type)
    return nil unless pay_type == 'warranty'

    row = billing.find { |b| b['billing_type'].to_s == 'warranty' && b['manufacturer_id'].present? }
    row && row['manufacturer_id']
  end

  def group_rows(parts, labor, billing, default_pay)
    grouped = {}

    parts.each_with_index do |part, index|
      pay = billing_for(billing, index, 'part') || default_pay
      grouped[pay] ||= { parts: [], labor: [] }
      grouped[pay][:parts] << normalize_part(part)
    end

    labor.each_with_index do |row, index|
      pay = billing_for(billing, index, 'labor') || default_pay
      grouped[pay] ||= { parts: [], labor: [] }
      grouped[pay][:labor] << normalize_labor(row)
    end

    grouped
  end

  def issue_title(ticket, pay_type, group_count)
    return ticket.title if group_count <= 1

    suffix = pay_type == 'warranty' ? 'Warranty' : 'Customer Pay'
    "#{ticket.title} (#{suffix})"
  end

  # Some legacy rows carry a `total` that disagrees with quantity x unitCost
  # (the stored total is what every existing report and claim has been reading).
  # Back-solve the unit amount so the money is preserved exactly rather than
  # silently restated.
  def reconcile(count, rate, stored_total)
    return [count, rate] if stored_total.nil?

    stored = stored_total.to_f
    return [count, rate] if (count * rate - stored).abs <= 0.01

    return [count, stored / count] if count.positive?

    [1.0, stored]
  end

  def normalize_part(part)
    quantity = (part['quantity'] || 0).to_f
    unit_cost = (part['unit_cost'] || part['unitCost'] || 0).to_f
    quantity, unit_cost = reconcile(quantity, unit_cost, part['total'])

    {
      'id' => SecureRandom.uuid,
      'partNumber' => part['part_number'] || part['partNumber'],
      'description' => part['description'],
      'partId' => part['part_id'] || part['partId'],
      'estQuantity' => nil,
      'estUnitCost' => nil,
      'actQuantity' => quantity,
      'actUnitCost' => unit_cost,
      'addedBy' => 'dealer',
      'confirmedAt' => nil
    }
  end

  def normalize_labor(row)
    hours = (row['hours'] || 0).to_f
    rate = (row['rate'] || 0).to_f
    hours, rate = reconcile(hours, rate, row['total'])

    {
      'id' => SecureRandom.uuid,
      'description' => row['description'],
      'estHours' => nil,
      'estRate' => nil,
      'actHours' => hours,
      'actRate' => rate,
      'addedBy' => 'dealer',
      'confirmedAt' => nil
    }
  end
end

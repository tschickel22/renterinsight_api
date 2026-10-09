# frozen_string_literal: true

module Truebuild
  # Change orders on a factory PO already sent (backlog E52, phase 1). The
  # LIVE Deal Sheet is compared with what the factory has (the PO's snapshot,
  # updated by each approved change order): lines added, removed, or changed
  # in quantity or cost, the home itself, and color and finish picks. One
  # change order is open at a time; a draft is brought up to date from the
  # sheet, a sent one waits for the factory. Approved, it rewrites the PO to
  # what it carried.
  module ChangeOrders
    module_function

    class Refused < StandardError; end

    # => { 'lines' => [...], 'colors' => [...], 'cost_delta' => n, 'snapshot' => {...} }
    def diff(po)
      build = po.deal&.home_build
      raise Refused, 'The deal has no LIVE Deal Sheet' unless build

      old = po.sheet_snapshot.to_h
      now_lines = FactoryOrder.lines(build)
      now_colors = FactoryOrder.colors(build)
      lines = line_changes(Array(old['lines']), now_lines)
      colors = color_changes(Array(old['colors']), now_colors)
      { 'lines' => lines, 'colors' => colors, 'cost_delta' => lines.sum { |l| l['cost_delta'].to_d }.round(2).to_s,
        'snapshot' => { 'lines' => now_lines, 'colors' => now_colors, 'version' => build.version_number, 'build_id' => build.id } }
    end

    def changed?(po) = po.factory_home? && !po.draft? && po.deal&.home_build && diff(po).values_at('lines', 'colors').any?(&:present?)

    def create!(po, user:, production_status: 'not_released', notes: nil)
      refuse_unless_changeable!(po)
      raise Refused, "#{po.change_orders.open.first.label} is still open: send, approve or void it first" if po.change_orders.open.exists?

      d = diff(po)
      raise Refused, 'The Deal Sheet matches what the factory has: there is nothing to change' if d.values_at('lines', 'colors').all?(&:empty?)

      po.change_orders.create!(
        company: po.company, deal: po.deal, deal_home_build: po.deal.home_build, number: po.change_orders.maximum(:number).to_i + 1,
        production_status: production_status.presence || 'not_released', notes: notes.presence, created_by: user,
        changes_list: d.slice('lines', 'colors'), new_snapshot: d['snapshot'], cost_delta: d['cost_delta']
      )
    end

    # A draft brought up to date with the sheet as it is now.
    def refresh!(co, production_status: nil, notes: nil)
      raise Refused, "#{co.label} was sent: void it and make a new one" unless co.status == 'draft'

      d = diff(co.purchase_order)
      co.update!(changes_list: d.slice('lines', 'colors'), new_snapshot: d['snapshot'], cost_delta: d['cost_delta'],
                 deal_home_build: co.purchase_order.deal.home_build,
                 production_status: production_status.presence || co.production_status, notes: notes.nil? ? co.notes : notes.presence)
      co
    end

    # The factory accepted it: the PO now carries what the change order did.
    def approve!(co)
      raise Refused, "#{co.label} is #{co.status}" unless co.open?

      po = co.purchase_order
      PurchaseOrder.transaction do
        po.lines.each(&:mark_for_destruction)
        Array(co.new_snapshot['lines']).each_with_index do |l, i|
          po.lines.build(line_number: i + 1, description: l['description'], manufacturer_part_no: l['code'],
                         catalog_option_id: l['option_id'], quantity_ordered: l['quantity'].to_d, unit_cost: l['unit_cost'].to_d)
        end
        po.sheet_snapshot = po.sheet_snapshot.to_h.merge(co.new_snapshot.slice('lines', 'colors', 'version'))
                              .merge('change_order' => co.number, 'written_at' => Time.current.iso8601)
        po.save!
        co.update!(status: 'approved', approved_at: Time.current)
      end
      co
    end

    def void!(co)
      raise Refused, "#{co.label} is #{co.status}" unless co.open?

      co.update!(status: 'void', voided_at: Time.current)
    end

    def refuse_unless_changeable!(po)
      raise Refused, 'Only a factory PO takes change orders' unless po.factory_home?
      raise Refused, "#{po.po_number} has not been sent: update it from the Deal Sheet instead" if po.draft?
      raise Refused, "#{po.po_number} is #{po.status}" if %w[received cancelled].include?(po.status)
    end

    def key(l) = l['kind'] == 'base' ? 'base' : (l['option_id'] ? "o#{l['option_id']}" : "d#{l['description']}")

    def line_changes(old, now)
      before = old.index_by { |l| key(l) }
      after = now.index_by { |l| key(l) }
      total = ->(l) { l ? l['quantity'].to_d * l['unit_cost'].to_d : 0.to_d }
      out = []
      (before.keys | after.keys).each do |k|
        a = before[k]
        b = after[k]
        next if a && b && a['description'] == b['description'] && a['quantity'].to_d == b['quantity'].to_d && a['unit_cost'].to_d == b['unit_cost'].to_d

        change = if a.nil? then 'add'
                 elsif b.nil? then 'remove'
                 elsif a['description'] != b['description'] then 'substitute'
                 elsif a['quantity'].to_d != b['quantity'].to_d then 'quantity'
                 else 'cost'
                 end
        out << { 'change' => change, 'description' => (b || a)['description'], 'was' => (a['description'] if change == 'substitute'),
                 'code' => (b || a)['code'], 'quantity_from' => a&.dig('quantity'), 'quantity_to' => b&.dig('quantity'),
                 'unit_cost_from' => a&.dig('unit_cost'), 'unit_cost_to' => b&.dig('unit_cost'),
                 'cost_delta' => (total.call(b) - total.call(a)).round(2).to_s }.compact
      end
      order = %w[substitute add quantity cost remove]
      out.sort_by { |l| [l['description'] == before['base']&.dig('description') ? 0 : 1, order.index(l['change']), l['description'].to_s] }
    end

    def color_changes(old, now)
      before = old.index_by { |c| c['set'] }
      now.filter_map do |c|
        was = before[c['set']]
        next if was && was['choice'] == c['choice'] && was['skipped'] == c['skipped']

        { 'set' => c['set'], 'from' => was&.dig('choice'), 'to' => c['choice'], 'code' => c['code'], 'skipped' => c['skipped'] }.compact
      end
    end
  end
end

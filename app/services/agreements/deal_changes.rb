# frozen_string_literal: true

module Agreements
  # Lines the dealer added or changed on an agreement's line-item rows (Form 500's
  # optional equipment, for example) that the deal doesn't have yet. The deal stays
  # the source of truth: the agreement offers these back, the dealer picks which to
  # keep, and `apply` writes them to the deal's lines. Nothing ever flows the other
  # way silently, and nothing is offered from a sent or signed agreement.
  #
  # A row is traced to its deal line by `deal.<array>[i].ref` ("dp:<id>"), which the
  # agreement saved when the row was filled from the deal. A row with no ref and
  # something typed in it is a new line.
  class DealChanges
    ROW_KEY = /\Adeal\.([a-z_]+)\[(\d+)\]\.([a-z_]+)\z/
    AMOUNT_COLUMNS = %w[line_total amount price total].freeze
    CATEGORY_ARRAYS = %w[land fee accessory service product other].freeze

    Result = Struct.new(:changes, :blocked_reason, :warning, keyword_init: true)

    def initialize(agreement)
      @agreement = agreement
      @deal = agreement.deal
    end

    def list
      reason = blocked_reason
      return Result.new(changes: [], blocked_reason: reason, warning: nil) if reason

      Result.new(changes: changes, blocked_reason: nil, warning: warning)
    end

    # Applies the chosen changes (ids from #list). Returns the agreement values
    # written so the builder can stay in step (new rows get their deal ref).
    def apply(ids)
      reason = blocked_reason
      raise ArgumentError, reason if reason

      chosen = changes.select { |c| ids.include?(c[:id]) && c[:blocked].nil? }
      written = {}
      DealProduct.transaction do
        chosen.each do |change|
          if change[:kind] == 'add'
            line = add_line(change)
            written["deal.#{change[:array]}[#{change[:row]}].ref"] = "dp:#{line.id}"
          else
            update_line(change)
          end
        end
        if written.any?
          values = (@agreement.merge_field_values || {}).merge(written)
          @agreement.update_columns(merge_field_values: values.deep_stringify_keys, updated_at: Time.current)
        end
      end
      { applied: chosen.size, merge_field_values: written }
    end

    private

    def blocked_reason
      return 'This agreement is not linked to a deal.' unless @deal
      return 'Sent and signed agreements never change the deal. Change the deal and make a new agreement.' unless @agreement.status == Agreement::STATUS_DRAFT
      if @deal.deal_desk_scenarios.selected.where.not(line_items: [nil, []]).exists?
        return 'This deal is priced in the Deal Desk. Change its lines there.'
      end

      nil
    end

    def warning
      return nil unless @deal.stage_is_won?

      'This deal is already closed. Changing its lines changes what it sold for; check its invoice.'
    end

    def values = @values ||= (@agreement.merge_field_values || {}).stringify_keys

    def deal_lines = @deal_lines ||= Agreements::DealLineItemsResolver.call(@deal).index_by { |li| li[:ref] }

    def products = @products ||= @deal.deal_products.index_by { |dp| "dp:#{dp.id}" }

    # array => { columns: Set, rows: [idx] } from where the template placed rows.
    def placed_arrays
      @placed_arrays ||= begin
        placements = Array(@agreement.merge_field_placements.presence || @agreement.field_placements)
        placements.each_with_object({}) do |p, out|
          m = ROW_KEY.match((p['fieldKey'] || p[:fieldKey]).to_s)
          next unless m && LineItemValuesFlattener::ARRAY_KEYS.include?(m[1])

          entry = out[m[1]] ||= { columns: [], rows: [] }
          entry[:columns] |= [m[3]]
          entry[:rows] |= [m[2].to_i]
        end
      end
    end

    def changes
      @changes ||= begin
        seen = {}
        placed_arrays.flat_map do |array, placed|
          amount_col = (AMOUNT_COLUMNS & placed[:columns]).first
          text_col = placed[:columns].include?('description') ? 'description' : ('name' if placed[:columns].include?('name'))
          next [] unless amount_col || text_col

          placed[:rows].sort.filter_map do |row|
            row_change(array, row, text_col, amount_col, placed[:columns].include?('tax_mark'), seen)
          end
        end
      end
    end

    def row_change(array, row, text_col, amount_col, has_mark, seen)
      at = ->(col) { col && values["deal.#{array}[#{row}].#{col}"].to_s.strip }
      text = at.call(text_col)
      amount = money(at.call(amount_col))
      taxable = has_mark ? at.call('tax_mark').blank? : nil
      ref = at.call('ref').presence || legacy_ref(array, text)

      if ref.present?
        return nil if seen[ref]

        seen[ref] = true
        line = deal_lines[ref]
        product = products[ref]
        return nil unless line && product && !line[:is_home]

        was_amount = money(line[amount_col.to_s.to_sym])
        text_changed = text_col && text.present? && text != line[:description].to_s.strip
        amount_changed = amount_col && amount && was_amount && (amount - was_amount).abs >= 0.005
        tax_changed = !taxable.nil? && taxable != line[:taxable]
        return nil unless text_changed || amount_changed || tax_changed

        changed_on_deal = product.updated_at > @agreement.created_at
        {
          id: "update:#{ref}", kind: 'update', ref: ref, array: array, row: row,
          description: text_col && text.present? ? text : line[:description],
          amount: amount_changed ? amount : was_amount,
          taxable: taxable.nil? ? line[:taxable] : taxable,
          was: { description: line[:description], amount: was_amount, taxable: line[:taxable] },
          tax: line_tax(product, amount_changed ? amount : was_amount, taxable.nil? ? line[:taxable] : taxable),
          default_on: !changed_on_deal,
          note: (changed_on_deal ? 'The deal line changed after this agreement was made; the deal may be the newer one.' : nil),
          blocked: (product.notes.to_s.match?(/deal_sheet:/i) ? 'This line comes from the deal sheet. Change it there.' : nil)
        }
      elsif text.present? || amount.to_f.nonzero?
        taxable = true if taxable.nil?
        {
          id: "add:#{array}:#{row}", kind: 'add', ref: nil, array: array, row: row,
          description: text.presence || 'Added on agreement', amount: amount.to_f, taxable: taxable,
          was: nil, tax: taxable ? (amount.to_f * deal_tax_rate).round(2) : 0.0,
          default_on: true, note: nil, blocked: nil
        }
      end
    end

    # Agreements saved before rows carried a ref: a row whose text matches a deal
    # line in the same list is that line, not a new one.
    def legacy_ref(array, text)
      return nil if text.blank?

      @arrays ||= LineItemValuesFlattener.build_arrays_by_key(deal_lines.values)
      match = Array(@arrays[array]).find { |li| li[:description].to_s.strip.casecmp?(text) }
      match && match[:ref]
    end

    def add_line(change)
      category = CATEGORY_ARRAYS.find { |c| change[:array] == "line_items_#{c}" } || 'accessory'
      notes = ["category:#{category}", ('taxable:no' unless change[:taxable])].compact.join(', ')
      @deal.deal_products.create!(
        product_name: change[:description], product_sku: "CUSTOM-#{SecureRandom.hex(4)}",
        quantity: 1, unit_price: change[:amount], cost: 0, discount: 0, discount_type: 'fixed',
        tax: change[:tax], notes: notes
      )
    end

    def update_line(change)
      product = products[change[:ref]]
      qty = product.quantity.to_f.positive? ? product.quantity.to_f : 1.0
      notes = product.notes.to_s.gsub(/,?\s*taxable:\s*\w+/i, '').sub(/\A,\s*/, '')
      notes = [notes.presence, 'taxable:no'].compact.join(', ') unless change[:taxable]
      product.update!(product_name: change[:description], unit_price: (change[:amount].to_f / qty).round(2),
                      tax: change[:tax], notes: notes)
    end

    # Tax for a changed line: its own rate if it had one, else the deal's.
    def line_tax(product, amount, taxable)
      return 0.0 unless taxable

      base = product.unit_price.to_f * product.quantity.to_f
      rate = base.positive? && product.tax.to_f.positive? ? product.tax.to_f / base : deal_tax_rate
      (amount.to_f * rate).round(2)
    end

    # The rate already on the deal's taxed lines (tax / price). 0 when none carry tax.
    def deal_tax_rate
      @deal_tax_rate ||= begin
        taxed = @deal.deal_products.select { |dp| dp.tax.to_f.positive? && dp.unit_price.to_f.positive? }
        base = taxed.sum { |dp| dp.unit_price.to_f * dp.quantity.to_f }
        base.positive? ? (taxed.sum { |dp| dp.tax.to_f } / base) : 0.0
      end
    end

    def money(raw)
      s = raw.to_s.delete('$,').strip
      return nil if s.empty?

      Float(s)
    rescue ArgumentError
      nil
    end
  end
end

# frozen_string_literal: true

module Truebuild
  # A new book's changes as one dealer sees them: cost and retail at their own
  # markup, before and after, for the review screen and the notice.
  class UpdateSummary
    LIST_LIMIT = 50

    def initialize(company, diff)
      @company = company
      @diff = diff
    end

    def call
      homes = @diff.home_changes.map { |c| home_row(c) }
      options = @diff.option_changes.map { |c| option_row(c) }
      {
        'features_only' => @diff.features_only?,
        'homes' => {
          'changed' => homes.size,
          'up' => homes.count { |h| h['cost_change'].positive? },
          'down' => homes.count { |h| h['cost_change'].negative? },
          'avg_pct' => avg_pct(homes),
          'added' => @diff.homes_added.size,
          'dropped' => @diff.homes_dropped.size,
          'rows' => homes.sort_by { |h| -h['cost_change'].abs }.first(LIST_LIMIT)
        },
        'options' => {
          'changed' => options.size,
          'up' => options.count { |o| o['cost_change'].positive? },
          'down' => options.count { |o| o['cost_change'].negative? },
          'avg_pct' => avg_pct(options),
          'rows' => options.sort_by { |o| -o['cost_change'].abs }.first(LIST_LIMIT),
          'added' => @diff.options_added.first(LIST_LIMIT).map(&:name),
          'added_count' => @diff.options_added.size,
          'dropped' => @diff.options_dropped.first(LIST_LIMIT).map(&:name),
          'dropped_count' => @diff.options_dropped.size
        },
        'features' => {
          'added' => @diff.features_added.first(LIST_LIMIT).map { |s, n| { 'series' => s.presence, 'name' => n } },
          'added_count' => @diff.features_added.size,
          'dropped' => @diff.features_dropped.first(LIST_LIMIT).map { |s, n| { 'series' => s.presence, 'name' => n } },
          'dropped_count' => @diff.features_dropped.size
        }
      }
    end

    private

    def home_row(c)
      v = c[:variant]
      {
        'variant_id' => v.id, 'label' => "#{v.catalog_plan.series} #{v.catalog_plan.name} (#{v.model_number})".strip,
        'old_cost' => c[:old_cost].to_f, 'new_cost' => c[:new_cost].to_f,
        'cost_change' => (c[:new_cost] - c[:old_cost]).to_f,
        'old_retail' => base_retail(v, @diff.old_book), 'new_retail' => base_retail(v, @diff.new_book)
      }
    end

    def option_row(c)
      {
        'option_id' => c[:option].id, 'label' => c[:option].name, 'group' => c[:option].group&.name,
        'applies_to' => applies_label(c[:price]),
        'old_cost' => c[:old_cost].to_f, 'new_cost' => c[:new_cost].to_f,
        'cost_change' => (c[:new_cost] - c[:old_cost]).to_f
      }
    end

    # The home's retail at this dealer's rules if priced from that book.
    def base_retail(variant, book)
      PricingEngine.new(company: @company, variant: variant, book: book).call.lines.first[:retail]
    rescue ArgumentError
      nil
    end

    def applies_label(op)
      parts = []
      parts << op.variant.model_number if op.variant
      parts << op.series if op.series.present?
      parts << op.building_code if op.building_code
      parts << "#{op.width_ft}' wide" if op.width_ft
      parts << "#{op.min_length_ft}'-#{op.max_length_ft}'" if op.min_length_ft || op.max_length_ft
      parts << op.section_type if op.section_type
      parts.join(', ').presence
    end

    def avg_pct(rows)
      pcts = rows.filter_map { |r| r['old_cost'].to_f.zero? ? nil : r['cost_change'] / r['old_cost'] * 100 }
      pcts.empty? ? 0 : (pcts.sum / pcts.size).round(1)
    end
  end
end

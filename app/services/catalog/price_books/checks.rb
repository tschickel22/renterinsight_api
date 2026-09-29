# frozen_string_literal: true

module Catalog
  module PriceBooks
    # Deterministic checks run on what the model extracted. In Phase 0 these
    # caught every gap the model left: a skipped page, a missed table, a sheet
    # that contradicts its own model numbers. Each returns flag strings that
    # land on the import item for the reviewer.
    module Checks
      MODEL_NUMBER = Classifier::MODEL_NUMBER

      module_function

      # Model numbers printed on a page's text layer, normalized.
      def model_numbers_in(text)
        text.to_s.scan(MODEL_NUMBER).map { |m| Catalog::ModelNumber.normalize(m) }.uniq
      end

      # The sheet disagrees with its own model number: 30' boxes coded 32,
      # a 4-bed Apex under a 3-bed code. Flagged, never "fixed".
      def model_code_flags(row)
        mn = Catalog::ModelNumber.parse(row['model_number'])
        return ['model_number_unrecognized'] unless mn.valid?

        printed = { width_ft: row['box_width_ft'], length_ft: row['box_length_ft'], beds: row['beds'], baths: row['baths'] }
        mn.conflicts_with(printed).map { |c| "model_code_#{c[:field].to_s.delete_suffix('_ft')}_mismatch" }
      end

      # Net base plus required adders should equal a printed total.
      def adder_flags(row)
        adders = Array(row['required_adders'])
        return [] if adders.empty? || row['total_base_price'].blank?

        sum = row['net_base_price'].to_d + adders.sum { |a| a['amount'].to_d }
        (sum - row['total_base_price'].to_d).abs > 1 ? ['adder_total_mismatch'] : []
      end

      # Retail over cost should match the tab's stated multiplier. Returns
      # [flags, dealer_cost, retail], swapping the two when the sheet's columns
      # were read the wrong way round (retail/cost == 1/markup).
      def markup_check(cost, retail, markup)
        return [[], cost, retail] unless cost.to_f.positive? && retail.to_f.positive? && markup.to_f.positive?

        ratio = retail.to_f / cost.to_f
        return [[], cost, retail] if (ratio - markup.to_f).abs < 0.03
        return [['cost_retail_swapped'], retail, cost] if ((1 / ratio) - markup.to_f).abs < 0.03

        [['markup_differs_from_tab'], cost, retail]
      end
    end
  end
end

# frozen_string_literal: true

module Truebuild
  # What moved between two books of the same plant: home base costs, option
  # costs, options added or dropped, and standard features added or dropped.
  # Cost only; Truebuild::UpdateSummary prices it at a dealer's markup.
  class BookDiff
    attr_reader :old_book, :new_book

    def initialize(old_book, new_book)
      @old_book = old_book
      @new_book = new_book
    end

    # [{ variant:, old_cost:, new_cost: }] for homes in both books whose cost moved.
    def home_changes
      @home_changes ||= begin
        old = old_book.variant_prices.index_by(&:catalog_plan_variant_id)
        new_book.variant_prices.includes(variant: :catalog_plan).filter_map do |vp|
          before = old[vp.catalog_plan_variant_id]
          next unless before && before.base_cost.to_d != vp.base_cost.to_d

          { variant: vp.variant, old_cost: before.base_cost.to_d, new_cost: vp.base_cost.to_d }
        end
      end
    end

    def homes_added
      @homes_added ||= variant_ids(new_book) - variant_ids(old_book)
    end

    def homes_dropped
      @homes_dropped ||= variant_ids(old_book) - variant_ids(new_book)
    end

    # Option price rows matched on option and applicability.
    def option_changes
      @option_changes ||= begin
        old = old_book.option_prices.index_by { |op| option_key(op) }
        new_book.option_prices.includes(option: :group).filter_map do |op|
          before = old[option_key(op)]
          next unless before && before.dealer_cost.to_d != op.dealer_cost.to_d && !op.is_standard

          { option: op.option, price: op, old_cost: before.dealer_cost.to_d, new_cost: op.dealer_cost.to_d }
        end
      end
    end

    def options_added
      @options_added ||= CatalogOption.where(id: option_ids(new_book) - option_ids(old_book)).order(:name).to_a
    end

    def options_dropped
      @options_dropped ||= CatalogOption.where(id: option_ids(old_book) - option_ids(new_book)).order(:name).to_a
    end

    def features_added = feature_set(new_book) - feature_set(old_book)
    def features_dropped = feature_set(old_book) - feature_set(new_book)

    # Nothing but features changed: no dealer price moves.
    def features_only?
      home_changes.empty? && option_changes.empty? && homes_added.empty? && homes_dropped.empty? &&
        options_added.empty? && options_dropped.empty?
    end

    private

    def variant_ids(book) = book.variant_prices.pluck(:catalog_plan_variant_id).to_set
    def option_ids(book) = book.option_prices.distinct.pluck(:catalog_option_id)

    def option_key(op)
      [op.catalog_option_id, op.catalog_plan_variant_id, op.series, op.min_length_ft, op.max_length_ft, op.width_ft,
       op.section_type, op.construction, op.building_code]
    end

    def feature_set(book)
      book.standard_features.pluck(:series, :name).map { |s, n| [s.to_s, n.strip] }.to_set
    end
  end
end

# frozen_string_literal: true

# Master-list (coded) options carry section and length in their names too
# ("Ash Trim ... T/O - Sect", "... LA - SW"), but have no per-row import item,
# so RepairCatalogOptionApplicability skipped them (an earlier regroup also
# re-keyed them from coded-- to other--). Fill section and length from the
# option name where a row has none. Never overwrites a value. Idempotent.
class RepairCodedOptionApplicability < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:catalog_option_prices)

    CatalogOptionPrice.reset_column_information
    CatalogOptionPrice.where(catalog_plan_variant_id: nil).includes(:option).find_each do |row|
      where = Catalog::PriceBooks::Applicability.resolve(name: row.option.name, tab: nil, series_list: [])
      attrs = {}
      attrs[:section_type] = where['section_type'] if row.section_type.nil? && where['section_type']
      if row.min_length_ft.nil? && row.max_length_ft.nil? && (where['min_length_ft'] || where['max_length_ft'])
        attrs[:min_length_ft] = where['min_length_ft']
        attrs[:max_length_ft] = where['max_length_ft']
      end
      row.update_columns(attrs.merge(updated_at: Time.current)) if attrs.any?
    end
  end

  def down; end
end

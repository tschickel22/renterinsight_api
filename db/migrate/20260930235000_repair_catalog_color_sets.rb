# frozen_string_literal: true

# Colors in the published Champion book carry neither their tab's series
# (DGAE siding colors were offered on Aspire homes) nor the set a buyer picks
# one from (siding, shutters, countertop). Reads each color row's import item
# for its tab and set title. Platform catalog data only; idempotent.
class RepairCatalogColorSets < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:catalog_option_prices)

    [CatalogOption, CatalogOptionPrice, CatalogImportItem].each(&:reset_column_information)
    CatalogPriceBook.where.not(status: %w[draft extracting rejected]).find_each do |book|
      series_list = CatalogPlan.where(manufacturer_id: book.manufacturer_id).distinct.pluck(:series)
      items = book.import_items.where(item_type: 'option').where("payload->>'kind' = 'color'").group_by(&:source_ref)

      book.option_prices.joins(:option).where(catalog_options: { kind: 'color' }).includes(:option).find_each do |row|
        item = Array(items[row.source_ref]).find do |i|
          Catalog::PriceBooks::Keys.option(i.payload['group'], i.payload['name']) == row.option.key ||
            "#{Catalog::PriceBooks::Keys.group(i.payload['group'])}--#{i.payload['name'].to_s.parameterize[0, 90]}" == row.option.key
        end
        next unless item

        row.update_columns(series: Catalog::PriceBooks::Applicability.series_for(item.payload['tab'].to_s, series_list),
                           updated_at: Time.current)
        set = Catalog::PriceBooks::ColorSets.normalize(item.payload['group'])
        next if row.option.metadata['color_set'] == set

        row.option.update_columns(metadata: row.option.metadata.merge('color_set' => set), updated_at: Time.current)
      end
    end
  end

  def down; end
end

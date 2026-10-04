# frozen_string_literal: true

# The first published TrueBuild book (Champion Topeka, staging) priced
# options for the wrong homes: no row carried its tab's series, "Sect" rows on
# the Aspire DW tab were marked single section, and options that differ only
# by a comparison ("SW<=60' box", "SW >60' box") were merged into one.
# Catalog::PriceBooks::Applicability and Keys now get this right at publish;
# this applies the same rules to rows already published, reading each row's
# import item for its name and tab. Platform catalog data only; idempotent.
class RepairCatalogOptionApplicability < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:catalog_option_prices)

    [CatalogOption, CatalogOptionPrice, CatalogImportItem].each(&:reset_column_information)
    CatalogPriceBook.where.not(status: %w[draft extracting rejected]).find_each { |book| repair(book) }
  end

  def down; end

  private

  def legacy_key(p)
    "#{Catalog::PriceBooks::Keys.group(p['section'])}--#{p['description'].to_s.parameterize[0, 90]}"
  end

  def repair(book)
    # Color and coded rows can share a sheet-level source_ref with option
    # rows, so a row only takes an item whose old-style key is the row's
    # current option key, and only when exactly one does.
    items = book.import_items.where(item_type: 'option_price').group_by(&:source_ref)
    series_list = CatalogPlan.where(manufacturer_id: book.manufacturer_id).distinct.pluck(:series)
    touched = Set.new

    book.option_prices.includes(:option).find_each do |row|
      candidates = Array(items[row.source_ref]).select { |i| legacy_key(i.payload) == row.option.key }
      next unless candidates.size == 1

      item = candidates.first

      p = item.payload
      where = Catalog::PriceBooks::Applicability.resolve(
        name: p['description'], tab: p['tab'], series_list: series_list,
        model_specific: row.catalog_plan_variant_id.present?, ai: p['applies_to'] || {}
      )
      attrs = where

      key = Catalog::PriceBooks::Keys.option(p['section'], p['description'])
      if row.option.key != key
        touched << row.catalog_option_id
        target = CatalogOption.find_by(manufacturer_id: book.manufacturer_id, key: key) ||
                 row.option.dup.tap do |o|
                   o.assign_attributes(key: key, name: p['description'].to_s.truncate(250), factory_code: nil)
                   o.save!
                 end
        attrs = attrs.merge('catalog_option_id' => target.id)
      end
      row.update_columns(attrs.merge('updated_at' => Time.current))
    end

    touched.each do |id|
      next if CatalogOptionPrice.exists?(catalog_option_id: id)

      CatalogOptionRule.where(catalog_option_id: id).or(CatalogOptionRule.where(target_option_id: id)).delete_all
      CatalogOption.where(replaced_by_id: id).update_all(replaced_by_id: nil)
      CatalogOption.where(id: id).delete_all
    end
  end
end

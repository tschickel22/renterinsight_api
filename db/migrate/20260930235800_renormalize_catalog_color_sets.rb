# frozen_string_literal: true

# ColorSets now folds siding product lines ("4200 Series", "4400 Series
# Shadow") into Siding. Re-run stored set names through it. Idempotent.
class RenormalizeCatalogColorSets < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:catalog_options)

    CatalogOption.reset_column_information
    CatalogOption.where(kind: 'color').where("metadata ? 'color_set'").find_each do |o|
      set = Catalog::PriceBooks::ColorSets.normalize(o.metadata['color_set'])
      o.update_columns(metadata: o.metadata.merge('color_set' => set)) if set != o.metadata['color_set']
    end
  end

  def down; end
end

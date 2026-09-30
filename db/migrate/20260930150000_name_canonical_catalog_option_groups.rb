# frozen_string_literal: true

# Groups whose key already matched a canonical group (see
# Catalog::PriceBooks::Sections) were left with the factory's wording and no
# position by the regroup ("Appliances", "Plumbing/Heating"). Give every
# canonical group its name and order.
class NameCanonicalCatalogOptionGroups < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:catalog_option_groups)

    Catalog::PriceBooks::Sections::GROUPS.each_with_index do |(key, name, _), i|
      execute ActiveRecord::Base.sanitize_sql(
        ['UPDATE catalog_option_groups SET name = ?, position = ? WHERE key = ?', name, i, key]
      )
    end
    other_key, other_name = Catalog::PriceBooks::Sections::OTHER
    execute ActiveRecord::Base.sanitize_sql(
      ['UPDATE catalog_option_groups SET name = ?, position = ? WHERE key = ?', other_name,
       Catalog::PriceBooks::Sections::GROUPS.size, other_key]
    )
  end

  def down; end
end

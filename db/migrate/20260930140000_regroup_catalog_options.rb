# frozen_string_literal: true

# The first published TrueBuild book (Champion Topeka, staging) made one
# option group per factory section: 108 of them, including "Cabinets" and
# "Cabinets Cont.", "Carpet" and "Carpet Colors", and 25 sections named after
# a single model. Catalog::PriceBooks::Sections now maps sections onto about
# 20 groups; this moves published options onto them, merges options that
# were split across a section and its continuation, and ties model-specific
# option prices to their model. Platform catalog data only.
class RegroupCatalogOptions < ActiveRecord::Migration[8.0]
  def up
    return unless table_exists?(:catalog_options)

    CatalogOptionGroup.reset_column_information
    CatalogOption.reset_column_information

    CatalogOptionGroup.find_each.group_by { |g| [g.manufacturer_id, g.factory_id] }.each do |(mfr, factory), groups|
      targets = {}
      groups.each do |old|
        key, name = Catalog::PriceBooks::Sections.group_for(old.name)
        next if key == old.key

        target = targets[key] ||= CatalogOptionGroup.where(manufacturer_id: mfr, factory_id: factory, series: nil, key: key)
                                                    .first_or_create!(name: name, selection_type: 'multiple',
                                                                      position: Catalog::PriceBooks::Sections::GROUPS.index { |k, _, _| k == key } || 99)
        model = Catalog::PriceBooks::Sections.model_number_in(old.name)
        CatalogOption.where(catalog_option_group_id: old.id).find_each do |opt|
          link_model_prices(opt, mfr, model) if model
          new_key = "#{key}--#{opt.name.to_s.parameterize[0, 90]}"
          survivor = CatalogOption.where(manufacturer_id: mfr, key: new_key).where.not(id: opt.id).first
          if survivor
            CatalogOptionPrice.where(catalog_option_id: opt.id).update_all(catalog_option_id: survivor.id)
            CatalogOptionRule.where(catalog_option_id: opt.id).delete_all
            CatalogOptionRule.where(target_option_id: opt.id).delete_all
            CatalogOption.where(replaced_by_id: opt.id).update_all(replaced_by_id: survivor.id)
            survivor.update_columns(factory_code: survivor.factory_code || opt.factory_code)
            opt.delete
          else
            opt.update_columns(catalog_option_group_id: target.id, key: new_key,
                               metadata: opt.metadata.merge('section' => opt.metadata['section'] || old.name))
          end
        end
        old.delete if CatalogOption.where(catalog_option_group_id: old.id).none?
      end
    end
  end

  def down
    # Regrouping is not undone; the old groups were a reading artifact.
  end

  private

  def link_model_prices(opt, mfr, model_number)
    variants = CatalogPlanVariant.where(manufacturer_id: mfr, model_number: model_number).pluck(:id)
    return unless variants.size == 1

    CatalogOptionPrice.where(catalog_option_id: opt.id, catalog_plan_variant_id: nil).update_all(catalog_plan_variant_id: variants.first)
  end
end

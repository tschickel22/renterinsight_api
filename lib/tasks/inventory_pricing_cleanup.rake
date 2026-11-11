# frozen_string_literal: true

# Pricing tab rebuild cleanup (Tom 2026-11-11). Every task lists what it would
# change and changes nothing unless APPLY=1.
#
#   bin/rails inventory_pricing:sync_sale_price            # list
#   APPLY=1 bin/rails inventory_pricing:sync_sale_price    # change
namespace :inventory_pricing do
  def apply? = ENV['APPLY'] == '1'

  desc 'Homes with no discount whose old sale_price differs from the asking price (msrp): set sale_price to it'
  task sync_sale_price: :environment do
    scope = Vehicle.where(is_deleted: [false, nil]).where.not(status: 'sold')
                   .where(special_discount_enabled: [false, nil])
                   .where('msrp > 0 AND sale_price IS NOT NULL AND sale_price <> msrp')
    scope.order(:company_id, :id).each do |v|
      puts [v.company_id, v.id, v.inventory_id, "#{v.year} #{v.make} #{v.model}".squish, "sale_price #{v.sale_price.to_f}", "asking #{v.msrp.to_f}"].join(' | ')
      v.update_columns(sale_price: v.msrp, updated_at: Time.current) if apply?
    end
    puts "#{scope.count} home(s)#{apply? ? ' changed' : ' (dry run; APPLY=1 to change)'}"
  end

  desc 'Homes on a price list that also have an asking price typed (now wins on deal sheets): list only'
  task typed_on_price_list: :environment do
    scope = Vehicle.where(is_deleted: [false, nil]).where.not(status: 'sold').where.not(catalog_plan_variant_id: nil)
                   .where('msrp > 0 OR (sale_price > 0 AND COALESCE(special_discount_enabled, false) = false)')
    scope.includes(:company, :catalog_plan_variant).order(:company_id, :id).each do |v|
      book = Truebuild::InventoryPricing.new(v.company).summary(v)
      puts [v.company_id, v.id, v.inventory_id, v.catalog_plan_variant&.model_number, "asking #{(v.msrp || v.sale_price).to_f}",
            "price list #{book ? book[:retail].round(2) : 'none'}"].join(' | ')
    end
    puts "#{scope.count} home(s)"
  end

  HIDDEN_PRICING_KEYS = %w[rent_price rent_to_own_price deposit_amount lot_rent utilities terms holdback_amount target_gross minimum_price].freeze

  desc 'Saved inventory page layouts: hide rent, rent-to-own, deposit, lot rent, utilities, terms, holdback, target gross, minimum price'
  task hide_layout_fields: :environment do
    changed = 0
    PageLayout.where(module_name: %w[inventory inventory_mh inventory_rv]).find_each do |layout|
      data = layout.layout_data.deep_dup
      hits = []
      Array(data['sections']).each do |section|
        Array(section['fields']).each do |f|
          next unless HIDDEN_PRICING_KEYS.include?(f['key']) && f['visible'] != false

          f['visible'] = false
          hits << f['key']
        end
      end
      next if hits.empty?

      changed += 1
      puts [layout.company_id, layout.module_name, layout.layout_type, hits.join(',')].join(' | ')
      layout.update!(layout_data: data) if apply?
    end
    puts "#{changed} layout(s)#{apply? ? ' changed' : ' (dry run; APPLY=1 to change)'}"
  end
end

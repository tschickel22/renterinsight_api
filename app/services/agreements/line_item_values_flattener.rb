# frozen_string_literal: true

module Agreements
  # Turns a deal's line items into the *indexed, flat* keys that PDF rendering
  # actually consumes. The template author places field pairs with keys like:
  #
  #   deal.line_items[0].description
  #   deal.line_items[0].amount
  #   deal.line_items[1].description
  #   deal.line_items[1].amount
  #   ...
  #
  # ...and this flattener writes the corresponding values into the values_map.
  # Bulk-drop N pre-numbered rows in the template builder, and any indexes past
  # the number of actual line items just get empty strings so the extra rows
  # print blank.
  #
  # The same flattening is applied to the filtered per-category arrays and to
  # non_home_line_items so template authors can pick the array that fits the
  # form section they're building.
  module LineItemValuesFlattener
    # Every array-shaped merge field key we need to flatten, in the order they
    # are exposed by AgreementMergeFieldsController.
    ARRAY_KEYS = %w[
      line_items
      non_home_line_items
      line_items_home
      line_items_land
      line_items_fee
      line_items_accessory
      line_items_service
      line_items_product
      line_items_other
    ].freeze

    # Fields per line item that we surface as `deal.<array>[i].<field>`.
    ITEM_FIELDS = %w[description name amount price cost quantity line_total total category source is_home].freeze

    def self.apply!(values_map, deal)
      return values_map unless deal

      all_items = ::Agreements::DealLineItemsResolver.call(deal)
      by_key = build_arrays_by_key(all_items)

      by_key.each do |array_key, items|
        items.each_with_index do |item, idx|
          ITEM_FIELDS.each do |f|
            values_map["deal.#{array_key}[#{idx}].#{f}"] = stringify(item[f.to_sym])
          end
        end
      end

      values_map
    end

    def self.build_arrays_by_key(all_items)
      {
        'line_items'          => all_items,
        'non_home_line_items' => all_items.reject { |li| li[:is_home] },
        'line_items_home'      => all_items.select { |li| li[:category].to_s == 'home' },
        'line_items_land'      => all_items.select { |li| li[:category].to_s == 'land' },
        'line_items_fee'       => all_items.select { |li| li[:category].to_s == 'fee' },
        'line_items_accessory' => all_items.select { |li| li[:category].to_s == 'accessory' },
        'line_items_service'   => all_items.select { |li| li[:category].to_s == 'service' },
        'line_items_product'   => all_items.select { |li| li[:category].to_s == 'product' },
        'line_items_other'     => all_items.select { |li| li[:category].to_s == 'other' },
      }
    end

    def self.stringify(v)
      case v
      when nil then ''
      when true then 'Yes'
      when false then 'No'
      when Float, BigDecimal then v.to_s
      else v.to_s
      end
    end
  end
end

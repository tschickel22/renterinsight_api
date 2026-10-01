# frozen_string_literal: true

module McpTools
  class ListInventory < ListTool
    tool_name 'list_inventory'
    title 'List inventory'
    description 'List inventory units (homes, RVs, vehicles). Filter by status, bedrooms, price range, or how ' \
                'long they have been in stock; sort=aging lists the oldest stock first. Prices are retail; ' \
                'dealer cost appears under costs only when the dealer allows AI apps to see it.'
    input_schema(
      properties: {
        status: { type: 'string', enum: Vehicle::STATUSES },
        min_bedrooms: { type: 'integer', minimum: 0 },
        min_price: { type: 'number' },
        max_price: { type: 'number' },
        min_days_in_stock: { type: 'integer', minimum: 0 },
        query: { type: 'string', description: 'Stock number, VIN, serial, make or model contains' },
        sort: { type: 'string', enum: %w[newest aging price_low price_high] },
        limit: { type: 'integer', minimum: 1, maximum: Context::MAX_ROWS }
      }
    )

    def self.perform(ctx, status: nil, min_bedrooms: nil, min_price: nil, max_price: nil, min_days_in_stock: nil,
                     query: nil, sort: 'newest', limit: 20)
      records = Records.new(ctx)
      rel = records.scope('unit')
      rel = rel.where(id: records.search('unit', query, 500).map(&:id)) if query.present?
      rel = rel.where(status: status) if status.present?
      rel = rel.where('vehicles.bedrooms >= ?', min_bedrooms) if min_bedrooms.present?
      rel = rel.where('vehicles.sale_price >= ?', min_price) if min_price.present?
      rel = rel.where('vehicles.sale_price <= ?', max_price) if max_price.present?
      rel = rel.where('vehicles.date_in_stock <= ?', min_days_in_stock.to_i.days.ago.to_date) if min_days_in_stock.present?
      rel = case sort
            when 'aging' then rel.order(Arel.sql('vehicles.date_in_stock ASC NULLS LAST'))
            when 'price_low' then rel.order(Arel.sql('vehicles.sale_price ASC NULLS LAST'))
            when 'price_high' then rel.order(Arel.sql('vehicles.sale_price DESC NULLS LAST'))
            else rel.order(created_at: :desc)
            end
      listing(ctx, 'unit', rel, limit)
    end
  end
end

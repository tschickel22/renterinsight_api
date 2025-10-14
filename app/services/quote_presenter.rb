# frozen_string_literal: true

class QuotePresenter
  def self.basic_json(quote)
    {
      id: quote.id,
      quote_number: quote.quote_number,
      status: quote.status,
      subtotal: format_money(quote.subtotal),
      tax: format_money(quote.tax),
      total: format_money(quote.total),
      valid_until: quote.valid_until,
      sent_at: quote.sent_at,
      viewed_at: quote.viewed_at,
      accepted_at: quote.accepted_at,
      rejected_at: quote.rejected_at,
      created_at: quote.created_at,
      updated_at: quote.updated_at
    }
  end
  
  def self.detailed_json(quote)
    basic_json(quote).merge(
      items: format_items(quote.items),
      notes: quote.notes,
      custom_fields: quote.custom_fields || {},
      vehicle_info: vehicle_info(quote),
      account_info: account_info(quote)
    )
  end
  
  private
  
  def self.format_money(amount)
    amount.to_f.round(2).to_s
  end
  
  def self.format_items(items)
    return [] unless items.is_a?(Array)
    
    items.map do |item|
      next nil unless item.is_a?(Hash)
      
      {
        description: item['description'] || item[:description],
        quantity: item['quantity'] || item[:quantity],
        unit_price: format_money(item['unit_price'] || item[:unit_price] || item['unitPrice'] || item[:unitPrice] || 0),
        total: format_money(item['total'] || item[:total] || 0)
      }
    end.compact
  end
  
  def self.vehicle_info(quote)
    return nil unless quote.vehicle_id.present?
    
    {
      vehicle_id: quote.vehicle_id
      # Add more vehicle details when Vehicle model is implemented
    }
  end
  
  def self.account_info(quote)
    return nil unless quote.account.present?
    
    {
      id: quote.account.id,
      name: quote.account.name,
      email: quote.account.email,
      phone: quote.account.phone
    }
  end
end

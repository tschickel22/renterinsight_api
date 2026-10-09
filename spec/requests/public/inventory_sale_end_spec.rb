# frozen_string_literal: true

require 'rails_helper'

# The inventory feed and a sale's end date (backlog E72): a site that copies
# the feed sees the sale, its base price and its last day, and once the date
# passes the feed shows the base price at once, before the hourly job runs.
RSpec.describe 'Inventory feed sale end date', type: :request do
  let(:company) do
    create(:company).tap { |c| c.update!(public_inventory_token: SecureRandom.hex(8), public_inventory_settings: { 'public_inventory_enabled' => true }) }
  end
  let(:today) { Time.current.in_time_zone(company.time_zone).to_date }

  def home(model, ends_on: nil, sale: true)
    Vehicle.create!(company: company, year: 2026, make: 'Champion', model: model, vin: "VIN#{SecureRandom.hex(6).upcase}", status: 'available',
                    is_deleted: false, msrp: 80_000, special_discount_enabled: sale, discount_type: (sale ? '$ Flat Amount' : nil),
                    discount_value: (sale ? 5000 : nil), special_discount_ends_on: ends_on)
  end

  def item(model)
    get '/public/inventory', params: { token: company.public_inventory_token, statuses: 'available' }
    JSON.parse(response.body)['items'].find { |i| i['model'] == model }
  end

  it 'shows a running sale with its last day, the base price once it ends, and the base price with no sale' do
    home('Running', ends_on: today)
    expect(item('Running')).to include('price' => 75_000.0, 'price_type' => 'sale', 'sale_price' => 75_000.0, 'base_price' => 80_000.0,
                                       'on_sale' => true, 'sale_ends_on' => today.iso8601)

    home('Ended', ends_on: today - 1) # the hourly job has not run yet
    expect(item('Ended')).to include('price' => 80_000.0, 'price_type' => 'base', 'sale_price' => nil, 'on_sale' => false, 'sale_ends_on' => nil)

    home('Standard', sale: false)
    expect(item('Standard')).to include('price' => 80_000.0, 'price_type' => 'base', 'on_sale' => false)
  end
end

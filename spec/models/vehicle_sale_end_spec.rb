# frozen_string_literal: true

require 'rails_helper'

# A home's sale ends on its end date (backlog E72): it shows all of that day
# in the dealer's time zone, and the next day the discount turns off and the
# home shows its base price.
RSpec.describe Vehicle, '#sale_expired? and .expire_sales!' do
  let(:company) { create(:company) }

  def home(ends_on)
    Vehicle.create!(company: company, year: 2026, make: 'Champion', model: 'Bay Port', vin: "VIN#{SecureRandom.hex(6).upcase}",
                    status: 'available', is_deleted: false, msrp: 80_000, special_discount_enabled: true,
                    discount_type: '$ Flat Amount', discount_value: 5000, special_discount_ends_on: ends_on)
  end

  it 'ends a sale the day after its end date and leaves running sales alone' do
    today = Time.current.in_time_zone(company.time_zone).to_date
    ended = home(today - 1)
    last_day = home(today)
    open_ended = home(nil)
    expect(ended.reload.sale_price.to_f).to eq(75_000.0)

    expect(Vehicle.expire_sales!).to eq(1)
    expect(ended.reload).to have_attributes(special_discount_enabled: false, sale_price: nil, discounted_price: nil)
    expect(last_day.reload).to have_attributes(special_discount_enabled: true)
    expect(last_day.sale_price.to_f).to eq(75_000.0)
    expect(open_ended.reload.special_discount_enabled).to be(true)
  end
end

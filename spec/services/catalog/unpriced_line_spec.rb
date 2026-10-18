# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Catalog::UnpricedLine do
  let(:spec) do
    { manufacturer: { name: "Timber Creek Housing #{SecureRandom.hex(2)}", code: "TC#{SecureRandom.hex(2)}" },
      factory: { name: 'Bear Creek', code: 'BEAR', city: 'Bear Creek', state: 'AL' },
      book: { name: 'Timber Creek 2026 finishes (no prices)' },
      groups: [{ key: 'exterior', name: 'Exterior', position: 1,
                 sets: [{ name: 'Siding', options: [{ name: 'Graystone', standard: true, swatch: { image_url: 'https://b/graystone.jpg', hex: '#8a8a86', page: 2 } },
                                                    { name: 'Midnight', standard: false }] }] }],
      models: [{ number: 'CS-3240', name: 'The Cedar Creek', series: 'Creekside', width_ft: 32, length_ft: 76, beds: 4, baths: 2 }] }
  end

  it 'loads models and finishes with no prices, offers them to a dealer without pricing, and links feed homes by name' do
    result = described_class.load!(spec)
    described_class.load!(spec) # again: updates, adds nothing
    variant = CatalogPlanVariant.find_by(model_number: 'CS-3240')
    expect(variant).to have_attributes(unpriced?: true, width_ft: 32, length_ft: 76)
    expect(CatalogPlanVariant.designable).to include(variant)
    expect(CatalogOption.where(manufacturer: result[:manufacturer]).count).to eq(2)
    prices = result[:book].option_prices.includes(:option).index_by { |p| p.option.name }
    expect(prices['Graystone']).to have_attributes(is_standard: true, price_on_request?: false)
    expect(prices['Midnight']).to have_attributes(is_standard: false, price_on_request?: true, dealer_cost: nil)
    expect(CatalogSwatch.find_by(manufacturer: result[:manufacturer], name: 'Graystone').hex).to eq('#8a8a86')

    company = Company.create!(name: "Dealer #{SecureRandom.hex(3)}")
    allow(company).to receive(:has_module?).and_return(true)
    result[:factory].update!(truebuild_released_at: Time.current)
    company.dealer_factories.create!(factory: result[:factory])
    expect(Truebuild::BuyerCatalog.available?(company, variant)).to be(true) # no markup rules needed

    home = company.vehicles.create!(make: 'Timber Creek', model: 'The Cedar Creek', year: 2026, width: 32, length: 76,
                                    status: 'available_to_order', serial_number: 'S1', vin: 'V1')
    expect(home.catalog_plan_variant_id).to eq(variant.id)
    other = company.vehicles.create!(make: 'Clayton', model: 'The Cedar Creek', year: 2026, serial_number: 'S2', vin: 'V2')
    expect(other.catalog_plan_variant_id).to be_nil # another builder's home of the same name

    engine = Truebuild::PricingEngine.new(company: company, variant: variant, option_ids: CatalogOption.where(manufacturer: result[:manufacturer]).pluck(:id)).call
    expect(engine.lines.map { |l| [l[:label].to_s[0, 9], l[:retail]] }).to include(['The Cedar', nil], ['Graystone', 0.0], ['Midnight', nil])
    expect(engine.totals[:retail]).to be_nil
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public TrueBuild', type: :request do
  let(:company) do
    create(:company, name: 'Summit Homes').tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8), public_inventory_settings: { 'public_inventory_enabled' => true })
    end
  end
  let(:token) { company.public_inventory_token }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Belvidere') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32392', width_ft: 28, length_ft: 56, building_code: 'HUD') }
  let(:other_variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2876H42180', width_ft: 28, length_ft: 76) }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published') }
  let(:kitchen) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'kitchen', name: 'Kitchen & Appliances', position: 7) }
  let(:exterior) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'exterior', name: 'Exterior', position: 5) }
  let!(:vehicle) do
    Vehicle.create!(company: company, year: 2026, make: 'Champion', model: 'Belvidere', vin: "VIN#{SecureRandom.hex(6).upcase}",
                    status: 'available', is_deleted: false, catalog_plan_variant: variant)
  end

  def option(group, name, **price)
    CatalogOption.create!(group: group, manufacturer: mfr, key: "#{group.key}--#{name.parameterize}", name: name,
                          kind: price.delete(:kind) || 'upgrade', metadata: price.delete(:metadata) || {}).tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, **price)
    end
  end

  let!(:fridge) { option(kitchen, 'Stainless Fridge', dealer_cost: 1000, suggested_retail: 1550) }
  let!(:dw_only) { option(kitchen, 'Island', dealer_cost: 2000, section_type: 'single') }
  let!(:other_model) { option(kitchen, 'Big Porch', dealer_cost: 900, variant: other_variant) }
  let!(:gas) { option(kitchen, 'Stainless Package - Gas', dealer_cost: 2000) }
  let!(:electric) { option(kitchen, 'Stainless Package - Electric', dealer_cost: 2000) }
  let!(:white) { option(exterior, 'White', kind: 'color', is_standard: true, metadata: { 'color_set' => 'Siding' }) }
  let!(:clay) { option(exterior, 'Clay', kind: 'color', is_standard: true, metadata: { 'color_set' => 'Siding' }) }

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 80_000)
    book.standard_features.create!(series: 'Dutch Aspire Sectionals', category: 'Kitchen', name: 'Shaker cabinets')
    book.standard_features.create!(series: 'Dutch Aspire Singles', category: 'Kitchen', name: 'Not for a sectional')
    book.standard_features.create!(series: 'Genesis Homes', category: 'Kitchen', name: 'Not for Aspire')
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    company.dealer_catalog_terms.create!(price_display: 'full')
  end

  it 'gives a buyer the options this home offers, at retail, with colors as one-of sets and no cost anywhere' do
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token }
    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)

    expect(body['base_price']).to eq(100_000.0)
    expect(body['base_monthly']).to eq(725) # 90,000 at 7.5% over 20 years
    kitchen_group = body['groups'].find { |g| g['name'] == 'Kitchen & Appliances' }
    expect(kitchen_group['options'].map { |o| [o['name'], o['price']] })
      .to eq([['Stainless Fridge', 1250.0], ['Stainless Package - Electric', 2500.0], ['Stainless Package - Gas', 2500.0]])
    expect(kitchen_group['options'].map { |o| o['family'] }.compact.uniq).to eq(['stainless package - {fuel}'])
    siding = body['groups'].find { |g| g['name'] == 'Exterior' }['color_sets']
    expect(siding).to match([{ 'name' => 'Siding', 'options' => [
      a_hash_including('name' => 'Clay', 'standard' => true), a_hash_including('name' => 'White', 'standard' => true)
    ] }])
    expect(body['standard_features']).to eq([{ 'category' => 'Kitchen', 'items' => ['Shaker cabinets'] }])
    expect(response.body).not_to match(/cost/i)
    expect(body['media']).to include('photos' => [], 'floor_plans' => [], 'tour_url' => nil)
  end

  it 'hides every price when the dealer does' do
    company.dealer_catalog_terms.first.update!(price_display: 'hidden')
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token }
    body = JSON.parse(response.body)
    expect(body['display']).to include('show_prices' => false)
    expect(body['base_price']).to be_nil
    expect(body['groups'].flat_map { |g| g['options'] }.map { |o| o['price'] }.uniq).to eq([nil])

    post '/public/truebuild/price', params: { token: token, variant_id: variant.id, option_ids: [fridge.id] }
    expect(JSON.parse(response.body)).to include('show_prices' => false, 'total' => nil, 'lines' => [])
  end

  it 'shows a monthly estimate but no price when the dealer shows monthly payments only' do
    company.dealer_catalog_terms.first.update!(price_display: 'monthly')
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token }
    body = JSON.parse(response.body)
    expect(body).to include('base_price' => nil, 'base_monthly' => 725)
    expect(body['display']).to include('show_prices' => false, 'show_monthly' => true)

    post '/public/truebuild/price', params: { token: token, variant_id: variant.id, option_ids: [fridge.id] }
    expect(JSON.parse(response.body)).to include('total' => nil, 'monthly' => 734)
  end

  it 'prices a selection, dropping options this model does not offer' do
    post '/public/truebuild/price', params: { token: token, variant_id: variant.id, option_ids: [fridge.id, other_model.id, dw_only.id] }
    body = JSON.parse(response.body)
    expect(body['total']).to eq(101_250.0)
    expect(body['option_ids']).to eq([fridge.id])
  end

  it 'saves a design, creates the lead through the TrueBuild form, and opens by share link' do
    expect do
      post '/public/truebuild/designs', params: {
        token: token, variant_id: variant.id, vehicle_id: vehicle.id, option_ids: [fridge.id, clay.id],
        contact: { first_name: 'Tia', last_name: 'May', email: 'Tia@Example.com', phone: '3035550142' },
        context: { page_url: 'https://summit.mydealertide.com/homes/belvidere-12?x=1', utm_source: 'facebook' }
      }
    end.to change(TruebuildDesign, :count).by(1)
    expect(response).to have_http_status(:created)
    body = JSON.parse(response.body)
    expect(body['price']['total']).to eq(101_250.0)

    design = TruebuildDesign.last
    expect(design).to have_attributes(buyer_email: 'tia@example.com', option_ids: [fridge.id, clay.id], vehicle_id: vehicle.id)
    form = design.intake_submission.intake_form
    expect(form.source.name).to eq('TrueBuild')
    expect(design.intake_submission.data['Message']).to include('Stainless Fridge', '$101,250',
                                                                "https://summit.mydealertide.com/homes/belvidere-12?design=#{design.public_token}")
    # The ad that brought them is kept, but the lead is a TrueBuild lead so its play starts.
    expect(design.lead).to have_attributes(email: 'tia@example.com', source_id: form.source_id, utm_source: 'facebook')

    get "/public/truebuild/designs/#{design.public_token}", params: { token: token }
    expect(JSON.parse(response.body)).to include('name' => 'Belvidere (2856H32392)', 'option_ids' => [fridge.id, clay.id])
    expect(design.reload.view_count).to eq(1)
  end

  it 'refuses a save without an email, a home it cannot design, and a wrong token' do
    post '/public/truebuild/designs', params: { token: token, variant_id: variant.id, contact: { first_name: 'Tia' } }
    expect(response).to have_http_status(:unprocessable_entity)

    unlinked = Vehicle.create!(company: company, year: 2026, make: 'X', model: 'Y', vin: "VIN#{SecureRandom.hex(6).upcase}",
                               status: 'available', is_deleted: false)
    get "/public/truebuild/homes/#{unlinked.id}", params: { token: token }
    expect(response).to have_http_status(:not_found)

    get "/public/truebuild/homes/#{vehicle.id}", params: { token: 'nope' }
    expect(response).to have_http_status(:unauthorized)
  end

  it 'tells the home page whether the home can be designed' do
    get "/public/inventory/#{vehicle.id}", params: { token: token }
    expect(JSON.parse(response.body)['truebuild']).to eq('available' => true)
  end

  it "shows the manufacturer's photos and floor plan for a linked home with none of its own" do
    variant.update!(media: { 'photos' => [{ 'url' => 'https://img/kitchen-1', 'room' => 'kitchen' }],
                             'floor_plans' => ['https://img/plan'], 'matterport_url' => 'https://my.matterport.com/show/?m=x' })
    get "/public/inventory/#{vehicle.id}", params: { token: token }
    home = JSON.parse(response.body)['vehicle']
    expect(home).to include('image_urls' => ['https://img/kitchen-1'], 'floor_plan_images' => ['https://img/plan'],
                            'tour_url' => 'https://my.matterport.com/show/?m=x')
  end
end

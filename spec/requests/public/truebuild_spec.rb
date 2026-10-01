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
  let(:floor_plan) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'floor-plan', name: 'Floor Plan Options', position: 1) }
  let!(:shutter_black) { option(floor_plan, 'Shutters: Black', kind: 'standard', is_standard: true) }
  let!(:siding_olive) { option(floor_plan, 'Siding: Olive', kind: 'standard', is_standard: true) }
  let!(:roofing) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'roofing', name: 'Roofing', position: 4) }
  let!(:shingles) { option(floor_plan, '3 Tab Shingles: Black Weatherwood', kind: 'standard', is_standard: true) }

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
    expect(body['base_monthly']).to eq(697) # the dealer's calculator: 90,000 at 6.99% over 240 months
    kitchen_group = body['groups'].find { |g| g['name'] == 'Kitchen & Appliances' }
    expect(kitchen_group['options'].map { |o| [o['name'], o['price']] })
      .to eq([['Stainless Package - Electric', 2500.0], ['Stainless Package - Gas', 2500.0], ['Stainless Fridge', 1250.0]])
    expect(kitchen_group['options'].map { |o| o['family'] }.compact.uniq).to eq(['appliance package'])
    expect(body['standard_features']).to eq([{ 'category' => 'Kitchen', 'items' => ['Shaker cabinets'] }])
    # "Shutters: Black" is a color to choose, filed under Exterior, not an included Floor Plan option.
    sets = body['groups'].find { |g| g['name'] == 'Exterior' }['color_sets'].to_h { |st| [st['name'], st['options'].map { |o| o['name'] }] }
    expect(sets).to eq('Shutters' => ['Black'], 'Siding' => %w[Clay Olive White])
    expect(body['groups'].map { |g| g['name'] }).not_to include('Floor Plan Options')
    expect(body['groups'].find { |g| g['name'] == 'Roofing' }['color_sets']).to match([a_hash_including('name' => 'Shingles')])
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
    expect(body).to include('base_price' => nil, 'base_monthly' => 697)
    expect(body['display']['payment_terms']).to include('down_pct' => 10.0, 'apr' => 6.99, 'years' => 20.0)
    expect(body['display']).to include('show_prices' => false, 'show_monthly' => true)

    post '/public/truebuild/price', params: { token: token, variant_id: variant.id, option_ids: [fridge.id] }
    expect(JSON.parse(response.body)).to include('total' => nil, 'monthly' => 706)

    company.update!(loan_settings: { 'calculator_enabled' => false })
    get "/public/truebuild/homes/#{vehicle.id}", params: { token: token }
    expect(JSON.parse(response.body)).to include('base_monthly' => nil)
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

  it 'lists the models a dealer offers, with a starting price and photo' do
    variant.update!(media: { 'elevations' => ['https://img/front'] })
    get '/public/truebuild/models', params: { token: token }
    models = JSON.parse(response.body)['models']
    expect(models.size).to eq(1)
    expect(models.first).to include('name' => 'Belvidere', 'series' => 'Aspire', 'starting_price' => 100_000.0,
                                    'starting_monthly' => 697, 'image' => 'https://img/front', 'sizes' => ["28' x 56'"])
    expect(models.first['variants'].map { |v| v['id'] }).to eq([variant.id])
    expect(response.body).not_to match(/cost/i)
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

  describe 'TrueView' do
    let(:front) { 'https://s7d9.scene7.com/is/image/championhomes/belvidere-exterior-1' }
    # "None" is the photo as built, never drawn.
    let!(:no_corner) { option(exterior, 'None', kind: 'color', is_standard: true, metadata: { 'color_set' => 'Corner posts' }) }

    around do |ex|
      old = ENV['GEMINI_API_KEY']
      ENV['GEMINI_API_KEY'] = 'test'
      ex.run
    ensure
      ENV['GEMINI_API_KEY'] = old
    end

    before { variant.update!(media: { 'photos' => [{ 'url' => front, 'room' => 'exterior' }, { 'url' => 'https://x/bed.jpg', 'room' => 'bedroom' }] }) }

    def trueview = (get "/public/truebuild/models/#{variant.id}/trueview", params: { token: token }) && JSON.parse(response.body)

    it 'queues a layer per exterior finish on the first visit and shows each as it is drawn' do
      body = nil
      expect { body = trueview }.to have_enqueued_job(TruebuildRenderJob).on_queue('low').exactly(5).times
      expect(body['photos'].first).to include('room' => 'exterior', 'url' => "#{front}?wid=1600&fmt=jpeg&qlt=90", 'layers' => {})
      expect(body['photos'].first['pending']).to include(clay.id, white.id)
      expect(body['drawing']).to eq(5)
      expect(TruebuildRender.pluck(:selection).map { |s| s.first.values_at('surface', 'value') })
        .to contain_exactly(%w[Siding Clay], %w[Siding Olive], %w[Siding White], %w[Shutters Black], ['Shingles', 'Black Weatherwood'])

      TruebuildRender.find_by("selection->0->>'value' = 'Clay'")
                     .update!(status: 'done', layer_url: 'https://b/clay.webp', usage: { 'mask_version' => Truebuild::Trueview::Layer::VERSION })
      expect { body = trueview }.not_to have_enqueued_job(TruebuildRenderJob)
      expect(body['photos'].first['layers']).to eq(clay.id.to_s => 'https://b/clay.webp')
      expect(body['photos'].first['pending']).not_to include(clay.id)
      expect(body['drawing']).to eq(4)
    end

    it 'cuts an older drawing again for free instead of paying for a new one' do
      trueview
      clay_row = TruebuildRender.find_by("selection->0->>'value' = 'Clay'")
      clay_row.update!(status: 'done', image_url: 'https://b/clay.png', layer_url: 'https://b/clay-v2.webp', usage: { 'mask_version' => 2 })
      TruebuildRender.where.not(id: clay_row.id).delete_all

      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      ENV['TRUEVIEW_DAILY_LIMIT'] = '0'
      trueview
      recut = TruebuildRender.where("usage ? 'recut_from'").sole
      expect(recut).to have_attributes(image_url: 'https://b/clay.png', status: 'queued')
      expect(recut.usage['recut_from']).to eq(clay_row.id)
    ensure
      ENV.delete('TRUEVIEW_DAILY_LIMIT')
    end

    it 'puts a job lost in a restart back on the queue' do
      trueview
      lost = TruebuildRender.first
      lost.update_columns(status: 'running', updated_at: 1.hour.ago)
      expect { trueview }.to have_enqueued_job(TruebuildRenderJob).with(lost.id)
      expect(lost.reload.status).to eq('queued')
    end

    it 'stops drawing for the day at the platform limit' do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::MemoryStore.new)
      ENV['TRUEVIEW_DAILY_LIMIT'] = '2'
      expect { trueview }.to have_enqueued_job(TruebuildRenderJob).exactly(2).times
    ensure
      ENV.delete('TRUEVIEW_DAILY_LIMIT')
    end

    it 'draws nothing when the image key is not set' do
      ENV.delete('GEMINI_API_KEY')
      expect { trueview }.not_to have_enqueued_job(TruebuildRenderJob)
      expect(response).to have_http_status(:ok)
    end
  end
end

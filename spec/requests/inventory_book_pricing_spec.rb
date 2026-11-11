# frozen_string_literal: true

require 'rails_helper'

# E98 (Tom 2026-11-10): a home on the lot linked to a price book model shows
# the deal sheet selling price, worked out live, never written onto the home.
# One number on the list; itemized on the home with cost only for people who
# may see cost; "before surcharge" when no surcharge applies; on a website
# only when the dealer shows prices.
RSpec.describe 'Inventory price book pricing', type: :request do
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, factory: factory, series: 'Aspire', name: 'Belvidere') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856M32392', width_ft: 28, length_ft: 56) }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published') }
  let(:company) do
    Company.create!(name: "Dealer #{SecureRandom.hex(3)}").tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8), public_inventory_settings: { 'public_inventory_enabled' => true })
    end
  end
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@ex.com", first_name: 'A', last_name: 'D', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }

  def home(attrs = {})
    Vehicle.create!({ company: company, year: 2026, make: 'Champion', model: 'Belvidere', vin: "VIN#{SecureRandom.hex(6).upcase}",
                      status: 'available', is_deleted: false, listing_type: 'manufactured_home', bedrooms: 3, bathrooms: 2, catalog_plan_variant_id: variant.id }.merge(attrs))
  end

  before do
    CatalogVariantPrice.create!(price_book: book, variant: variant, net_base_price: 60_000, required_adders: [])
    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'multiplier', value: 1.5)
  end

  describe Truebuild::InventoryPricing do
    it 'prices a linked home as the price list does, marks it before surcharge, and writes nothing' do
      v = home(pack_amount: 2_000)
      sum = described_class.new(company).summary(v)
      expect(sum).to eq(retail: 93_000.0, before_surcharge: true) # (60,000 + 2,000) x 1.5
      expect(v.reload.msrp).to be_nil
    end

    it 'counts the surcharge when the dealer has one, and the label goes' do
      CatalogVariantPrice.find_by(variant: variant).update!(required_adders: [{ name: 'Surcharge', amount: 4_000 }])
      expect(described_class.new(company).summary(home)).to eq(retail: 96_000.0, before_surcharge: false)
    end

    it 'leaves cost out unless asked, and can be turned off per builder' do
      v = home
      pricing = described_class.new(company)
      expect(pricing.breakdown(v, include_cost: false).keys).not_to include(:cost, :factory_base, :program_discount)
      expect(pricing.breakdown(v, include_cost: true)).to include(factory_base: 60_000.0, cost: 60_000.0)

      company.dealer_catalog_terms.create!(manufacturer_id: nil, inventory_book_pricing: true)
      company.dealer_catalog_terms.create!(manufacturer_id: mfr.id, inventory_book_pricing: false)
      expect(described_class.new(company).summary(v)).to be_nil
    end

    it 'gives nothing for an unlinked home or one no rule covers' do
      expect(described_class.new(company).summary(home(catalog_plan_variant_id: nil))).to be_nil
      company.dealer_markup_rules.destroy_all
      expect(described_class.new(company).summary(home)).to be_nil
    end
  end

  describe 'GET /api/v1/vehicles' do
    it 'adds the figure only when the inventory list asks for it' do
      v = home
      get '/api/v1/vehicles', params: { include_book_price: 'true', per_page: 25 }, headers: headers
      row = JSON.parse(response.body)['vehicles'].find { |x| x['id'].to_s == v.id.to_s }
      expect(row['bookPrice']).to eq('retail' => 90_000.0, 'before_surcharge' => true)

      get '/api/v1/vehicles', params: { per_page: 25 }, headers: headers
      expect(JSON.parse(response.body)['vehicles'].find { |x| x['id'].to_s == v.id.to_s }).not_to have_key('bookPrice')
    end

    describe 'one list price, sorted and filtered (Tom 2026-11-11)' do
      def ids_for(params)
        get '/api/v1/vehicles', params: { per_page: 25, include_book_price: 'true' }.merge(params), headers: headers
        JSON.parse(response.body)['vehicles'].map { |x| x['id'].to_s }
      end

      let!(:linked) { home }                                       # no asking price: the price list's 90,000
      let!(:asked) { home(msrp: 40_000) }                          # on a price list, asking price wins
      let!(:typed) { home(catalog_plan_variant_id: nil, msrp: 70_000) }
      let!(:unpriced) { home(catalog_plan_variant_id: nil) }

      it 'shows the asking price when one is typed, else the marked-up price' do
        get '/api/v1/vehicles', params: { per_page: 25, include_book_price: 'true' }, headers: headers
        rows = JSON.parse(response.body)['vehicles'].index_by { |x| x['id'].to_s }
        expect(rows[linked.id.to_s]['listPrice']).to eq('amount' => 90_000.0, 'source' => 'book', 'beforeSurcharge' => true)
        expect(rows[asked.id.to_s]['listPrice']).to eq('amount' => 40_000.0, 'source' => 'home', 'beforeSurcharge' => false)
        expect(rows[typed.id.to_s]['listPrice']).to eq('amount' => 70_000.0, 'source' => 'home', 'beforeSurcharge' => false)
        expect(rows[unpriced.id.to_s]['listPrice']).to be_nil
      end

      it 'sorts every page by that price, homes with no price last' do
        expect(ids_for(sort_by: 'list_price', sort_order: 'desc')).to eq([linked, typed, asked, unpriced].map { |v| v.id.to_s })
        expect(ids_for(sort_by: 'list_price', sort_order: 'asc', per_page: 1, page: 2)).to eq([typed.id.to_s])
        expect(JSON.parse(response.body).dig('meta', 'total_count')).to eq(4)
      end

      it 'filters on that price' do
        expect(ids_for(min_price: 80_000)).to eq([linked.id.to_s])
        expect(ids_for(max_price: 50_000)).to eq([asked.id.to_s])
      end

      it 'ignores a sort key that is not a column' do
        expect(ids_for(sort_by: 'id; drop table vehicles', sort_order: 'sideways').size).to eq(4)
        expect(response).to have_http_status(:ok)
      end
    end

    describe 'the Pricing tab summary' do
      it 'fills factory price and surcharge from the price list, with gross and margin' do
        CatalogVariantPrice.find_by(variant: variant).update!(required_adders: [{ name: 'Surcharge', amount: 4_000 }])
        v = home
        get "/api/v1/vehicles/#{v.id}", headers: headers
        sum = JSON.parse(response.body).dig('vehicle', 'pricingSummary')
        expect(sum).to include('listed' => 96_000.0, 'listed_from' => 'marked_up', 'on_price_list' => true)
        expect(sum['cost']).to include('factory_price' => 60_000.0, 'factory_price_from' => 'price_list', 'surcharge' => 4_000.0,
                                       'surcharge_from' => 'price_list', 'total' => 64_000.0, 'your_cost' => 64_000.0)
        expect(sum['gross']).to eq(32_000.0)
        expect(sum['margin_pct']).to eq(33.3)
        expect(sum.dig('markup', 'times')).to eq(1.5)
      end

      it 'takes the invoice surcharge first and never adds it to an invoice cost twice' do
        v = home(catalog_plan_variant_id: nil, dealer_cost: 70_000, surcharge_amount: 3_000, msrp: 100_000)
        expect(v.structured_cost).to eq(73_000.0)
        VehicleInvoice.create!(vehicle: v, company: company, material_surcharge: 2_500, gross_invoice: 70_000)
        v.reload
        expect(v.structured_cost).to eq(70_000.0)
        get "/api/v1/vehicles/#{v.id}", headers: headers
        cost = JSON.parse(response.body).dig('vehicle', 'pricingSummary', 'cost')
        expect(cost).to include('surcharge' => 2_500.0, 'surcharge_from' => 'invoice', 'surcharge_in_total' => 'included', 'total' => 70_000.0)
      end
    end

    it 'itemizes on the home, with cost for someone who may see it' do
      v = home
      get "/api/v1/vehicles/#{v.id}", headers: headers
      pricing = JSON.parse(response.body)['vehicle']['bookPricing']
      expect(pricing).to include('retail' => 90_000.0, 'before_surcharge' => true, 'cost' => 60_000.0, 'book_name' => 'Topeka 2026')
    end
  end

  describe 'public website' do
    # TrueBuild prices start hidden; a dealer who shows them gets the figure.
    let!(:shown) { company.dealer_catalog_terms.create!(manufacturer_id: nil, price_display: 'full') }

    def public_price(v)
      get '/public/inventory', params: { token: company.public_inventory_token }
      JSON.parse(response.body)['items'].find { |i| i['id'].to_s == v.id.to_s }
    end

    it 'shows the selling price, never cost, for a home with no price of its own' do
      v = home
      item = public_price(v)
      expect(item).to include('price' => 90_000.0, 'price_source' => 'price_book')
      expect(response.body).not_to include('60000')
    end

    it 'keeps a typed price and shows nothing when the dealer hides prices' do
      typed = home(msrp: 99_000)
      expect(public_price(typed)).to include('price' => 99_000.0, 'price_source' => nil)

      shown.update!(price_display: 'hidden')
      expect(public_price(home)['price']).to be_nil
    end
  end
end

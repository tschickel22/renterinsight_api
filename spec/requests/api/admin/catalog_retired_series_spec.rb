# frozen_string_literal: true

require 'rails_helper'

# A plant stops building a series (Champion Genesis at Topeka): a platform
# admin retires it, its models leave the Deal Sheet's picker and stay retired
# through a new book, and restoring brings them back.
RSpec.describe 'Retired series', type: :request do
  let(:platform) { Company.create!(name: "Platform #{SecureRandom.hex(3)}") }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka, Dutch Housing', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2026', status: 'published', published_at: 1.day.ago) }
  let(:admin) do
    user = User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                        company_id: platform.id, role: 'platform_admin')
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: platform.id)}", 'Content-Type' => 'application/json' }
  end

  def model(series, name, number)
    plan = CatalogPlan.create!(manufacturer: mfr, factory: factory, series: series, name: name)
    CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: number, width_ft: 28, length_ft: 56)
                      .tap { |v| CatalogVariantPrice.create!(price_book: book, variant: v, net_base_price: 60_000) }
  end

  it "retires a plant's series, keeps it retired through a publish, and restores it" do
    aspire = model('Aspire', 'Easton', '2856M32301')
    genesis = model('Champion Genesis', 'Champion Genesis 301', '2856M32302')

    get "/api/admin/catalog_price_books/#{book.id}/series", headers: admin
    expect(JSON.parse(response.body)['series']).to contain_exactly(
      include('name' => 'Aspire', 'active' => 1, 'retired' => false), include('name' => 'Champion Genesis', 'active' => 1, 'retired' => false))

    post "/api/admin/catalog_price_books/#{book.id}/retire_series", headers: admin, params: { series: 'Champion Genesis' }.to_json
    expect(response).to have_http_status(:ok)
    expect(genesis.reload.status).to eq('discontinued')
    expect(aspire.reload.status).to eq('active')
    expect(Truebuild::HomeMatcher.new.variants.map(&:id)).to include(aspire.id)
    expect(Truebuild::HomeMatcher.new.variants.map(&:id)).not_to include(genesis.id)

    # A new book makes its models active again; the retirement is applied after it.
    genesis.update_columns(status: 'active')
    expect(Catalog::RetiredSeries.apply!(factory)).to eq(1)
    expect(genesis.reload.status).to eq('discontinued')

    post "/api/admin/catalog_price_books/#{book.id}/retire_series", headers: admin, params: { series: 'Champion Genesis', retire: false }.to_json
    expect(genesis.reload.status).to eq('active')
    expect(JSON.parse(response.body)['series'].find { |s| s['name'] == 'Champion Genesis' }).to include('retired' => false)

    post "/api/admin/catalog_price_books/#{book.id}/retire_series", headers: admin, params: { series: 'Nonexistent' }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
  end
end

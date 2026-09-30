# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/private_files_stub')

RSpec.describe 'Api::Admin::CatalogPriceBooks', type: :request do
  include ActiveJob::TestHelper

  let!(:s3) { stub_private_files }
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "pa-#{SecureRandom.hex(4)}@example.com", first_name: 'P', last_name: 'A', password: 'Pass1234!',
                 company_id: company.id, role: 'platform_admin')
  end
  let(:dealer) do
    User.create!(email: "d-#{SecureRandom.hex(4)}@example.com", first_name: 'D', last_name: 'U', password: 'Pass1234!',
                 company_id: company.id, role: 'admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" } }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_housing') }

  it 'is platform admin only' do
    get '/api/admin/catalog_price_books',
        headers: { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: dealer.id, company_id: company.id)}" }
    expect(response).to have_http_status(:forbidden)
  end

  it 'lists only platform manufacturers for the price book picker' do
    mfr
    own = Manufacturer.create!(name: 'Champion Athens', industry_type: 'manufactured_housing', company_id: company.id)
    get '/api/admin/manufacturers', headers: headers, params: { platform: true }
    ids = JSON.parse(response.body).map { |m| m['id'] }
    expect(ids).to include(mfr.id)
    expect(ids).not_to include(own.id)
  end

  it "lists a manufacturer's plants with how many books each has" do
    topeka = mfr.factories.create!(name: 'Topeka (Dutch Housing)', code: 'TOPEKA', city: 'Topeka', state: 'IN')
    CatalogPriceBook.create!(manufacturer: mfr, factory: topeka, name: '2025')
    get '/api/admin/catalog_price_books/factories', headers: headers, params: { manufacturer_id: mfr.id }
    expect(JSON.parse(response.body)['items']).to eq([{ 'id' => topeka.id, 'name' => 'Topeka (Dutch Housing)', 'city' => 'Topeka',
                                                        'state' => 'IN', 'price_books' => 1 }])
  end

  it 'refuses a dealer-owned manufacturer, since price books are platform data' do
    own = Manufacturer.create!(name: 'Dealer brand', industry_type: 'manufactured_housing', company_id: company.id)
    post '/api/admin/catalog_price_books', headers: headers, params: { manufacturer_id: own.id }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'creates a book with a new plant, takes an upload, and queues extraction' do
    post '/api/admin/catalog_price_books', headers: headers,
                                           params: { manufacturer_id: mfr.id, factory_name: 'Topeka', factory_city: 'Topeka', factory_state: 'IN' }
    expect(response).to have_http_status(:created)
    book = JSON.parse(response.body)
    expect(book.dig('factory', 'name')).to eq('Topeka')
    expect(book['name']).to include(mfr.name)

    pdf = Prawn::Document.new { |d| d.text "2856H32392 28' x 56' Belvidere 3 2 $57,995 NET Price" }.render
    file = Rack::Test::UploadedFile.new(StringIO.new(pdf), 'application/pdf', original_filename: 'Aspire Net.pdf')
    post "/api/admin/catalog_price_books/#{book['id']}/upload", headers: headers, params: { files: [file] }
    expect(response).to have_http_status(:created)
    expect(JSON.parse(response.body)['added'].first).to include('filename' => 'Aspire Net.pdf', 'kind' => 'price_list')

    expect { post "/api/admin/catalog_price_books/#{book['id']}/extract", headers: headers }
      .to have_enqueued_job(CatalogPriceBookExtractionJob)
    expect(CatalogPriceBook.find(book['id']).status).to eq('extracting')

    # A second click does not read the same file again.
    expect { post "/api/admin/catalog_price_books/#{book['id']}/extract", headers: headers }
      .not_to have_enqueued_job(CatalogPriceBookExtractionJob)
  end

  it 'lists items for review, approves the unflagged ones in bulk, and publishes' do
    book = CatalogPriceBook.create!(manufacturer: mfr, name: 'Topeka 2026', status: 'in_review')
    clean = book.import_items.create!(item_type: 'variant_price', payload: {
      'model_number' => '2856H32392', 'plan_name' => 'Belvidere', 'plan_series' => 'Aspire', 'building_code' => 'HUD', 'net_base_price' => 57_995
    })
    flagged = book.import_items.create!(item_type: 'variant_price', flags: ['model_code_width_mismatch'], payload: {
      'model_number' => '3260H32181', 'plan_name' => 'Shelby', 'plan_series' => 'Aspire', 'building_code' => 'HUD', 'net_base_price' => 67_395
    })

    get "/api/admin/catalog_price_books/#{book.id}/items", headers: headers, params: { flagged: true }
    body = JSON.parse(response.body)
    expect(body['items'].map { |i| i['id'] }).to eq([flagged.id])
    expect(body.dig('meta', 'counts', 'flagged_pending')).to eq(1)

    post "/api/admin/catalog_price_books/#{book.id}/bulk_review", headers: headers, params: { review_status: 'approved', unflagged: true }
    expect(JSON.parse(response.body)['updated']).to eq(1)
    expect(clean.reload.review_status).to eq('approved')

    post "/api/admin/catalog_price_books/#{book.id}/publish", headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(JSON.parse(response.body)['error']).to match(/1 items still need review/)

    patch "/api/admin/catalog_price_books/#{book.id}/items/#{flagged.id}", headers: headers,
                                                                           params: { payload: { width_ft: 30 } }
    expect(flagged.reload).to have_attributes(review_status: 'edited', reviewed_by_id: admin.id)
    expect(flagged.payload['width_ft']).to eq('30')

    perform_enqueued_jobs(only: CatalogPriceBookPublishJob) do
      post "/api/admin/catalog_price_books/#{book.id}/publish", headers: headers
      expect(response).to have_http_status(:accepted)
      expect(JSON.parse(response.body)['queued']).to be(true)
    end
    expect(book.reload.status).to eq('published')
    expect(book.metadata['publishing']).to include('state' => 'done', 'counts' => a_hash_including('variant_prices' => 2))

    patch "/api/admin/catalog_price_books/#{book.id}/items/#{clean.id}", headers: headers, params: { review_status: 'rejected' }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it "lets an admin choose a workbook's tabs, and reject everything read from one tab" do
    book = CatalogPriceBook.create!(manufacturer: mfr, name: 'Topeka 2026', status: 'in_review')
    doc = book.documents.create!(filename: 'Factory Options.xlsx', checksum_sha256: 'wb', kind: 'order_form', metadata: {
      'tab_list' => [{ 'name' => 'DGAE - HUD', 'rows' => 392, 'suggest_skip' => true }, { 'name' => '2023 DGAE HUD', 'rows' => 415 }],
      'selected_tabs' => ['2023 DGAE HUD']
    })
    patch "/api/admin/catalog_price_books/#{book.id}/documents/#{doc.id}/tabs", headers: headers,
                                                                               params: { selected_tabs: ['2023 DGAE HUD', 'DGAE - HUD'] }
    body = JSON.parse(response.body)
    expect(body['tabs'].map { |t| t['selected'] }).to eq([true, true])
    expect(body['estimate_usd']).to be > 1

    patch "/api/admin/catalog_price_books/#{book.id}/documents/#{doc.id}/tabs", headers: headers, params: { selected_tabs: ['Nope'] }
    expect(response).to have_http_status(:unprocessable_content)

    old = 2.times.map { book.import_items.create!(document: doc, item_type: 'option_price', source_ref: { 'sheet' => 'DGAE - HUD' }, payload: {}) }
    keep = book.import_items.create!(document: doc, item_type: 'option_price', source_ref: { 'sheet' => '2023 DGAE HUD' }, payload: {})
    post "/api/admin/catalog_price_books/#{book.id}/bulk_review", headers: headers,
                                                                 params: { review_status: 'rejected', sheet: 'DGAE - HUD', document_id: doc.id }
    expect(JSON.parse(response.body)['updated']).to eq(2)
    expect(old.map { |i| i.reload.review_status }).to all(eq('rejected'))
    expect(keep.reload.review_status).to eq('pending')
  end

  it 'shows what a published book put live' do
    book = CatalogPriceBook.create!(manufacturer: mfr, name: 'Topeka 2026', status: 'in_review')
    book.import_items.create!(item_type: 'variant_price', review_status: 'approved', payload: {
      'model_number' => '2856H32392', 'plan_name' => 'Belvidere', 'plan_series' => 'Aspire', 'building_code' => 'HUD', 'net_base_price' => 57_995
    })
    book.import_items.create!(item_type: 'option_price', review_status: 'approved', payload: {
      'tab' => '2025 Aspire DW', 'section' => 'Cabinets Cont.', 'description' => 'Cabinet Knobs', 'dealer_cost' => 65, 'suggested_retail' => 100.75
    })
    Catalog::PriceBooks::Publisher.new(book, by: admin).call

    get "/api/admin/catalog_price_books/#{book.id}/catalog", headers: headers
    body = JSON.parse(response.body)
    expect(body['plans'].first).to include('name' => 'Belvidere', 'series' => 'Aspire')
    expect(body['plans'].first['variants'].first).to include('model_number' => '2856H32392', 'net_base_price' => 57_995.0)
    expect(body['groups']).to eq([{ 'key' => 'cabinets', 'name' => 'Cabinets', 'position' => Catalog::PriceBooks::Sections::GROUPS.index { |k, _, _| k == 'cabinets' },
                                    'options' => 1, 'prices' => 1, 'model_specific' => 0, 'colors' => 0 }])
  end

  it 'hands out an expiring link to a source file' do
    book = CatalogPriceBook.create!(manufacturer: mfr, name: 'Topeka 2026')
    doc = book.documents.create!(filename: 'Aspire Net.pdf', checksum_sha256: 'abc', storage_bucket: 'dt-private-test',
                                 storage_key: "catalog/price-books/#{book.id}/abc_aspire_net.pdf")
    get "/api/admin/catalog_price_books/#{book.id}/documents/#{doc.id}/download", headers: headers
    expect(JSON.parse(response.body)['url']).to include('dt-private-test', 'X-Amz-Expires=600')
  end

  it 'sets the plant for a file or a tab, and relabels a published book' do
    topeka = mfr.factories.create!(name: 'Topeka', code: "T#{SecureRandom.hex(2)}")
    decatur = mfr.factories.create!(name: 'Decatur', code: "D#{SecureRandom.hex(2)}")
    book = CatalogPriceBook.create!(manufacturer: mfr, factory: topeka, name: 'Topeka 2026', status: 'published', published_at: Time.current)
    plan = CatalogPlan.create!(manufacturer: mfr, factory: topeka, series: 'Prime Of Indiana', name: 'P01')
    variant = CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '1676H32P01')
    doc = book.documents.create!(filename: 'prime.pdf', checksum_sha256: SecureRandom.hex(16), kind: 'price_list')
    book.import_items.create!(document: doc, item_type: 'variant_price', review_status: 'approved', payload: {},
                              matched_type: 'CatalogPlanVariant', matched_id: variant.id)
    sheet = book.documents.create!(filename: 'options.xlsx', checksum_sha256: SecureRandom.hex(16), kind: 'order_form',
                                   metadata: { 'tab_list' => [{ 'name' => 'Prime options' }] })

    patch "/api/admin/catalog_price_books/#{book.id}/documents/#{doc.id}/plant", headers: headers, params: { factory_id: decatur.id }
    expect(JSON.parse(response.body)['plant_id']).to eq(decatur.id)
    expect(plan.reload.factory_id).to eq(decatur.id)

    patch "/api/admin/catalog_price_books/#{book.id}/documents/#{sheet.id}/plant", headers: headers,
                                                                                  params: { factory_id: decatur.id, tab: 'Prime options' }
    get "/api/admin/catalog_price_books/#{book.id}/documents/#{sheet.id}/tabs", headers: headers
    expect(JSON.parse(response.body)['tabs'].first['plant_id']).to eq(decatur.id)
  end
end

# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/private_files_stub')

RSpec.describe 'Api::Admin::CatalogPriceBooks', type: :request do
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

    post "/api/admin/catalog_price_books/#{book.id}/publish", headers: headers
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['counts']).to include('variant_prices' => 2)
    expect(book.reload.status).to eq('published')

    patch "/api/admin/catalog_price_books/#{book.id}/items/#{clean.id}", headers: headers, params: { review_status: 'rejected' }
    expect(response).to have_http_status(:unprocessable_content)
  end

  it 'hands out an expiring link to a source file' do
    book = CatalogPriceBook.create!(manufacturer: mfr, name: 'Topeka 2026')
    doc = book.documents.create!(filename: 'Aspire Net.pdf', checksum_sha256: 'abc', storage_bucket: 'dt-private-test',
                                 storage_key: "catalog/price-books/#{book.id}/abc_aspire_net.pdf")
    get "/api/admin/catalog_price_books/#{book.id}/documents/#{doc.id}/download", headers: headers
    expect(JSON.parse(response.body)['url']).to include('dt-private-test', 'X-Amz-Expires=600')
  end
end

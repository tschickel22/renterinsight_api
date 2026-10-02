# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::Admin::CatalogOptionDecisions', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:factory) { mfr.factories.create!(name: 'Topeka', code: "TOP#{SecureRandom.hex(2)}") }
  let(:book) { CatalogPriceBook.create!(manufacturer: mfr, factory: factory, name: 'Topeka 2027', status: 'published') }
  let(:kitchen) { CatalogOptionGroup.create!(manufacturer: mfr, factory: factory, key: 'kitchen', name: 'Kitchen & Appliances', position: 7) }

  def headers_for(role)
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'S',
                        password: 'Pass1234!', company_id: company.id, role: role)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' }
  end

  let(:admin) { headers_for('platform_admin') }

  def option(name)
    CatalogOption.create!(group: kitchen, manufacturer: mfr, key: "kitchen--#{name.parameterize}", name: name, kind: 'upgrade').tap do |o|
      CatalogOptionPrice.create!(price_book: book, option: o, dealer_cost: 100)
    end
  end

  let!(:sxs) { option('Side by Side Fridge Upgrade') }
  let!(:french) { option('French Door Fridge Upgrade') }
  let!(:suggested) do
    [sxs, french].map do |o|
      CatalogOptionDecision.create!(manufacturer: mfr, option_key: o.key, kind: 'family', value: 'refrigerator', suggestion: 's1',
                                    note: 'One fridge per kitchen.', catalog_price_book: book)
    end
  end

  it 'lists suggestions with their options, and accepts or turns one down as a whole' do
    get "/api/admin/catalog_price_books/#{book.id}/option_decisions", headers: admin
    body = JSON.parse(response.body)
    expect(body['unreviewed']).to eq(1)
    expect(body['items'].sole).to include('kind' => 'family', 'value' => 'refrigerator', 'status' => 'active', 'note' => 'One fridge per kitchen.')
    expect(body['items'].sole['options'].map { |o| o['name'] }).to contain_exactly('Side by Side Fridge Upgrade', 'French Door Fridge Upgrade')

    patch "/api/admin/option_decisions/#{suggested.first.id}", headers: admin, params: { status: 'rejected' }.to_json
    expect(response).to have_http_status(:ok)
    expect(CatalogOptionDecision.where(suggestion: 's1').pluck(:status, :reviewed_at).map(&:first)).to eq(%w[rejected rejected])
    get "/api/admin/catalog_price_books/#{book.id}/option_decisions", headers: admin, params: { unreviewed: 1 }
    expect(JSON.parse(response.body)['items']).to eq([])
  end

  it "records an admin's own decision, and queues Claude to look again" do
    ice = option('Ice Maker Kit')
    post '/api/admin/option_decisions', headers: admin, params: { option_ids: [ice.id], kind: 'not_family', note: 'Goes with any fridge' }.to_json
    expect(response).to have_http_status(:created)
    expect(CatalogOptionDecision.find_by(option_key: ice.key)).to have_attributes(kind: 'not_family', source: 'admin', status: 'active')

    expect { post "/api/admin/catalog_price_books/#{book.id}/option_review", headers: admin }.to have_enqueued_job(CatalogOptionReviewJob).with(book.id)
  end

  it 'is platform admins only' do
    get "/api/admin/catalog_price_books/#{book.id}/option_decisions", headers: headers_for('admin')
    expect(response).to have_http_status(:forbidden)
  end
end

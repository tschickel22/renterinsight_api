# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1 land zoning options', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@ex.com", first_name: 'A', last_name: 'D', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:labels) { ->(body) { JSON.parse(body)['options'].map { |o| o['label'] } } }

  it 'offers the five built-in types until the company changes them' do
    get '/api/v1/company/land-zoning', headers: headers
    expect(labels.(response.body)).to eq(['Residential', 'Commercial', 'Agricultural', 'Industrial', 'Mixed Use'])
  end

  it 'adds a new type from the land form once, however it is typed' do
    post '/api/v1/company/land-zoning/add', headers: headers, params: { label: '  R-1  Single Family ' }.to_json
    expect(JSON.parse(response.body)['added']).to eq('value' => 'R-1 Single Family', 'label' => 'R-1 Single Family')

    post '/api/v1/company/land-zoning/add', headers: headers, params: { label: 'r-1 single family' }.to_json
    expect(labels.(response.body).count('R-1 Single Family')).to eq(1)
  end

  it 'saves removals and order, and a parcel keeps a type that was removed' do
    parcel = company.land_parcels.create!(parcel_number: 'P-1', status: 'available', zoning_type: 'Mixed Use')
    expect(parcel.zoning_type).to eq('mixed_use')

    put '/api/v1/company/land-zoning', headers: headers,
        params: { options: [{ label: 'Manufactured Home' }, { value: 'residential', label: 'Residential' }] }.to_json
    expect(labels.(response.body)).to eq(['Manufactured Home', 'Residential'])
    expect(parcel.reload.zoning_type).to eq('mixed_use')

    parcel.update!(zoning_type: 'Manufactured Home')
    expect(parcel.reload.zoning_type).to eq('Manufactured Home')
  end
end

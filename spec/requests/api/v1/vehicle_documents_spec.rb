# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::VehicleDocuments', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(
      email: "u-#{SecureRandom.hex(4)}@example.com",
      first_name: 'T', last_name: 'U',
      password: 'Pass1234!', company_id: company.id,
      role: 'platform_admin'
    )
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  let(:vehicle) do
    Vehicle.create!(
      company_id: company.id,
      listing_type: 'manufactured_home',
      status: 'available',
      year: 2024, make: 'Skyline', model: 'Test',
      serial_number: "SN-#{SecureRandom.hex(4)}",
      bedrooms: 3, bathrooms: 2
    )
  end

  describe 'GET /api/v1/vehicles/:vehicle_id/documents' do
    before do
      vehicle.documents.create!(title: 'Factory invoice',   category: 'factory',  visibility: 'internal')
      vehicle.documents.create!(title: 'Title docs',        category: 'title',    visibility: 'customer')
      vehicle.documents.create!(title: 'Public spec sheet', category: 'other',    visibility: 'public')
    end

    it 'returns all documents for the vehicle' do
      get "/api/v1/vehicles/#{vehicle.id}/documents", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body['documents'].size).to eq(3)
    end

    it 'filters by visibility' do
      get "/api/v1/vehicles/#{vehicle.id}/documents?visibility=internal", headers: auth_headers
      body = JSON.parse(response.body)
      expect(body['documents'].map { |d| d['visibility'] }.uniq).to eq(['internal'])
    end

    it 'denies access to vehicles in a different company' do
      other_company = Company.create!(name: 'Other')
      other_vehicle = Vehicle.create!(
        company_id: other_company.id, listing_type: 'rv', status: 'available',
        year: 2024, make: 'A', model: 'B', vin: "VIN-#{SecureRandom.hex(4)}"
      )
      get "/api/v1/vehicles/#{other_vehicle.id}/documents", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'POST /api/v1/vehicles/:vehicle_id/documents' do
    it 'creates a document with default internal visibility' do
      payload = { document: { title: 'Factory bill of sale', category: 'factory' } }.to_json
      post "/api/v1/vehicles/#{vehicle.id}/documents", params: payload, headers: auth_headers
      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body['document']['visibility']).to eq('internal')
      expect(body['document']['title']).to eq('Factory bill of sale')
      expect(body['document']['uploaded_by_user_id']).to eq(user.id)
    end

    it 'creates a document with explicit visibility' do
      payload = { document: { title: 'Public flyer', category: 'other', visibility: 'public' } }.to_json
      post "/api/v1/vehicles/#{vehicle.id}/documents", params: payload, headers: auth_headers
      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)['document']['visibility']).to eq('public')
    end

    it 'rejects invalid visibility' do
      payload = { document: { title: 'X', category: 'other', visibility: 'world' } }.to_json
      post "/api/v1/vehicles/#{vehicle.id}/documents", params: payload, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'rejects invalid category' do
      payload = { document: { title: 'X', category: 'mystery', visibility: 'internal' } }.to_json
      post "/api/v1/vehicles/#{vehicle.id}/documents", params: payload, headers: auth_headers
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'PATCH /api/v1/vehicles/:vehicle_id/documents/:id' do
    let!(:doc) { vehicle.documents.create!(title: 'A', category: 'other', visibility: 'internal') }

    it 'updates the document' do
      payload = { document: { visibility: 'customer', title: 'A (renamed)' } }.to_json
      patch "/api/v1/vehicles/#{vehicle.id}/documents/#{doc.id}", params: payload, headers: auth_headers
      expect(response).to have_http_status(:ok)
      expect(doc.reload.visibility).to eq('customer')
      expect(doc.title).to eq('A (renamed)')
    end
  end

  describe 'DELETE /api/v1/vehicles/:vehicle_id/documents/:id' do
    let!(:doc) { vehicle.documents.create!(title: 'A', category: 'other', visibility: 'internal') }

    it 'destroys the document' do
      delete "/api/v1/vehicles/#{vehicle.id}/documents/#{doc.id}", headers: auth_headers
      expect(response).to have_http_status(:no_content)
      expect(VehicleDocument.where(id: doc.id)).to be_empty
    end
  end

  describe 'visibility scopes' do
    it 'partitions documents correctly' do
      a = vehicle.documents.create!(title: 'int', category: 'other', visibility: 'internal')
      b = vehicle.documents.create!(title: 'cust', category: 'other', visibility: 'customer')
      c = vehicle.documents.create!(title: 'pub',  category: 'other', visibility: 'public')

      expect(vehicle.documents.internal.pluck(:id)).to eq([a.id])
      expect(vehicle.documents.customer_visible.pluck(:id)).to match_array([b.id, c.id])
      expect(vehicle.documents.public_visible.pluck(:id)).to eq([c.id])
    end
  end
end

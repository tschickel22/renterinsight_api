# frozen_string_literal: true

require 'rails_helper'

# A location-tier user sees location-less catalog homes in the inventory list,
# so opening one must not 404 (Easy Homesource, 2026-11-09).
RSpec.describe 'Opening a catalog home as a location-tier user', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:my_loc) { company.locations.create!(name: 'Mine') }
  let(:other_loc) { company.locations.create!(name: 'Other') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  def home(**attrs)
    company.vehicles.create!({ listing_type: 'manufactured_home', make: 'Clayton', model: 'Tulip', year: 2026,
                               serial_number: "S-#{SecureRandom.hex(3)}", bedrooms: 3, bathrooms: 2 }.merge(attrs))
  end

  before do
    allow_any_instance_of(User).to receive(:uses_rbac?).and_return(true)
    allow_any_instance_of(User).to receive(:effective_admin?).and_return(false)
    allow_any_instance_of(PermissionService).to receive(:accessible_location_ids).and_return([my_loc.id])
    allow_any_instance_of(Api::V1::VehiclesController).to receive(:authorize_action!).and_return(true)
  end

  it 'opens a location-less available-to-order home' do
    catalog = home(status: 'available_to_order', location_id: nil)
    get "/api/v1/vehicles/#{catalog.id}", headers: headers
    expect(response).to have_http_status(:ok)
  end

  it 'still hides a physical home at a location the user is not assigned to' do
    theirs = home(status: 'available', location_id: other_loc.id)
    get "/api/v1/vehicles/#{theirs.id}", headers: headers
    expect(response).to have_http_status(:not_found)
  end
end

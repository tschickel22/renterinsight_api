# frozen_string_literal: true

require 'rails_helper'

# A site's own access level wins over the dealer's plan, so it is a platform
# admin's call. A dealer able to set it could give themselves the full editor.
RSpec.describe 'Api::V1::Websites access level', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:location) { company.locations.create!(name: 'Brooksville') }
  let(:website) { company.websites.create!(location_id: location.id, name: 'EHS', slug: "s-#{SecureRandom.hex(4)}") }

  def headers_for(role)
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                        password: 'Pass1234!', company_id: company.id, role: role)
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}",
      'Content-Type' => 'application/json' }
  end

  it 'follows the plan until someone chooses a level' do
    expect(website.client_access_level).to be_nil
  end

  it 'lets a platform admin choose a level, and hand the site back to the plan' do
    headers = headers_for('platform_admin')

    patch "/api/v1/websites/#{website.id}", params: { website: { client_access_level: 3 } }.to_json, headers: headers
    expect(response).to have_http_status(:ok)
    expect(website.reload.client_access_level).to eq(3)

    patch "/api/v1/websites/#{website.id}", params: { website: { client_access_level: nil } }.to_json, headers: headers
    expect(website.reload.client_access_level).to be_nil
  end

  it 'ignores a level sent by a dealer while saving the rest' do
    website.update!(client_access_level: 1)

    patch "/api/v1/websites/#{website.id}", params: { website: { client_access_level: 3, name: 'Renamed' } }.to_json,
                                            headers: headers_for('admin')

    expect(website.reload.client_access_level).to eq(1)
    expect(website.name).to eq('Renamed') if response.successful?
  end
end

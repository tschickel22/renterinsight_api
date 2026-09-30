# frozen_string_literal: true

require 'rails_helper'

# The list the warranty claim and AR payment pickers read. It used to list
# only manufacturers with a floor plan in the retired configurator: none.
RSpec.describe 'GET /api/v1/manufacturers', type: :request do
  let(:company) { Company.create!(name: "Dealer #{SecureRandom.hex(3)}") }
  let(:other) { Company.create!(name: "Other #{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'D', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  it "lists platform manufacturers and the company's own, not another company's" do
    platform = Manufacturer.create!(name: "Champion #{SecureRandom.hex(2)}", industry_type: 'manufactured_home')
    own = Manufacturer.create!(name: "Local #{SecureRandom.hex(2)}", industry_type: 'rv', company: company)
    theirs = Manufacturer.create!(name: "Theirs #{SecureRandom.hex(2)}", industry_type: 'rv', company: other)

    get '/api/v1/manufacturers', headers: headers
    ids = JSON.parse(response.body)['items'].map { |m| m['id'] }
    expect(ids).to include(platform.id, own.id)
    expect(ids).not_to include(theirs.id)

    get '/api/v1/manufacturers', params: { industry_type: 'rv' }, headers: headers
    expect(JSON.parse(response.body)['items'].map { |m| m['id'] }).to include(own.id)
    expect(JSON.parse(response.body)['items'].map { |m| m['id'] }).not_to include(platform.id)
  end
end

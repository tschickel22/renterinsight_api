# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Plays start', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin', status: 'active')
  end
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'R', last_name: 'P',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let(:location) { company.inbound_lead_location }
  let(:other_company) { Company.create!(name: "Other-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  before { allow(Plays::LeadResponsePlay).to receive(:texting_ready?).and_return(false) }

  def body
    JSON.parse(response.body)
  end

  def lead(name, company_id: company.id)
    Lead.create!(company_id: company_id, first_name: name, last_name: 'Buyer', email: "#{name.downcase}-#{SecureRandom.hex(2)}@example.com")
  end

  it 'starts a play for chosen leads by adding its starting tag, once per lead' do
    Plays::WalkInVisit.new(company: company, user: user, answers: { 'reps_by_location' => { location.id.to_s => [rep.id] } }).install!
    tia = lead('Tia')
    sam = lead('Sam')
    stranger = lead('Stranger', company_id: other_company.id)

    post '/api/v1/plays/walk_in_visit/start', headers: headers, params: { lead_ids: [tia.id, sam.id, stranger.id] }.to_json

    expect(response).to have_http_status(:ok)
    expect(body).to eq('started' => 2, 'already_started' => 0, 'not_found' => 1, 'tag' => 'walk-in')
    expect(TagAssignment.where(entity_type: 'Lead', entity_id: [tia.id, sam.id]).count).to eq(2)
    expect(TagAssignment.where(entity_type: 'Lead', entity_id: stranger.id)).not_to exist

    post '/api/v1/plays/walk_in_visit/start', headers: headers, params: { lead_ids: [tia.id] }.to_json
    expect(body).to include('started' => 0, 'already_started' => 1)
  end

  it 'refuses a play that is off, one with no starting tag, and an empty selection' do
    post '/api/v1/plays/walk_in_visit/start', headers: headers, params: { lead_ids: [lead('Tia').id] }.to_json
    expect(response).to have_http_status(:not_found)

    Plays::WalkInVisit.new(company: company, user: user,
                           answers: { 'reps_by_location' => { location.id.to_s => [rep.id] }, 'start_tag' => '' }).install!
    post '/api/v1/plays/walk_in_visit/start', headers: headers, params: { lead_ids: [lead('Sam').id] }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to eq("Walk-in visit can't be started by hand.")

    Plays::WeeklyHomesEmail.new(company: company, user: user, answers: {}).install!
    post '/api/v1/plays/weekly_homes_email/start', headers: headers, params: { lead_ids: [] }.to_json
    expect(body['error']).to eq('Choose at least one lead.')
  end
end

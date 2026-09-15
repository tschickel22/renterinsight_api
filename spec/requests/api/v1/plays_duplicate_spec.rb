# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Plays duplicate', type: :request do
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
  let(:reps) { { company.inbound_lead_location.id.to_s => [rep.id] } }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Plays::LeadResponsePlay).to receive(:texting_ready?).and_return(false)
  end

  def body
    JSON.parse(response.body)
  end

  def duplicate(from, params)
    post "/api/v1/plays/#{from}/duplicate", headers: headers, params: params.to_json
  end

  it 'copies New Facebook lead for Google leads, and the copy works as its own play beside the original' do
    duplicate('new_facebook_lead', name: 'New Google lead', sources: ['Google'], start_tag: 'Google Lead')

    expect(response).to have_http_status(:created)
    copy = body['play']
    expect(copy['key']).to start_with('copy_')
    expect(copy).to include('name' => 'New Google lead', 'kind' => 'lead_response', 'default_sources' => ['Google'],
                            'default_start_tag' => 'google-lead', 'installation' => nil,
                            'copy_of' => { 'key' => 'new_facebook_lead', 'name' => 'New Facebook lead' })
    expect(copy['map'].first['title']).to eq('New lead from Google')

    get '/api/v1/plays', headers: headers
    expect(body['plays'].map { |p| p['name'] }).to include('New Google lead', 'New Facebook lead')

    post "/api/v1/plays/#{copy['key']}/install", headers: headers, params: { answers: { reps_by_location: reps } }.to_json
    expect(response).to have_http_status(:created)
    installation = body.dig('play', 'installation')
    expect(installation['sources']).to eq(['Google'])
    expect(installation['start_tag']).to eq('google-lead')
    expect(installation['intake_forms'].first).to include('name' => 'New Google lead Contact', 'source' => 'Google')

    post '/api/v1/plays/new_facebook_lead/install', headers: headers, params: { answers: { reps_by_location: reps } }.to_json
    expect(response).to have_http_status(:created)

    lead = Lead.create!(company_id: company.id, source_id: company.sources.find_by!(name: 'Google').id,
                        first_name: 'Gia', last_name: 'Lee', email: 'gia@example.com')
    DispatchWorkflowEventsJob.new.perform
    run = WorkflowRun.find_by(entity_type: 'Lead', entity_id: lead.id)
    expect(run.workflow_rule.name).to eq('New Google lead: new lead')
  end

  it 'will not reuse a source another play starts from' do
    post '/api/v1/plays/new_facebook_lead/install', headers: headers, params: { answers: { reps_by_location: reps } }.to_json
    duplicate('new_facebook_lead', name: 'Second Facebook', sources: ['Facebook'], start_tag: '')

    post "/api/v1/plays/#{body.dig('play', 'key')}/install", headers: headers, params: { answers: { reps_by_location: reps } }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to include('Facebook already starts New Facebook lead')
  end

  it 'refuses to copy a play that is not a lead response, a blank name, and a name in use' do
    duplicate('weekly_homes_email', name: 'Another weekly')
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to start_with('Only a lead response play')

    duplicate('new_facebook_lead', name: ' ')
    expect(body['error']).to eq('Name the new play.')

    duplicate('new_facebook_lead', name: 'walk-in visit')
    expect(body['error']).to eq('A play named walk-in visit already exists.')
  end

  it 'hides a copy like any other play' do
    duplicate('walk_in_visit', name: 'Open house visit', sources: ['Open House'])
    key = body.dig('play', 'key')

    post "/api/v1/plays/#{key}/dismiss", headers: headers
    get '/api/v1/plays', headers: headers
    expect(body['plays'].map { |p| p['key'] }).not_to include(key)
    get '/api/v1/plays?include_dismissed=true', headers: headers
    expect(body['plays'].find { |p| p['key'] == key }).to include('dismissed' => true)
  end
end

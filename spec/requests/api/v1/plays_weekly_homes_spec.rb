# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Plays weekly homes email', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin', status: 'active')
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  def body
    JSON.parse(response.body)
  end

  it 'offers the play with its choices and a preview of the email' do
    get '/api/v1/plays/weekly_homes_email', headers: headers

    expect(response).to have_http_status(:ok)
    play = body['play']
    expect(play).to include('kind' => 'recurring_email', 'installation' => nil)
    expect(play['sender_options']).to eq('company_mailbox' => false, 'users' => [])
    expect(play['map'].map { |s| s['key'] }).to eq(%w[trigger schedule weekly_email leave])
  end

  it 'turns on, customizes, reports and turns off' do
    post '/api/v1/plays/weekly_homes_email/install', headers: headers,
                                                      params: { answers: { content: { day: 'monday', time: '07:00' } } }.to_json
    expect(response).to have_http_status(:created)
    installation = body.dig('play', 'installation')
    expect(installation['campaign']).to include('status' => 'scheduled')
    expect(installation['campaign']['next_send_at']).to be_present
    expect(installation['sources']).to eq([])

    patch '/api/v1/plays/weekly_homes_email/customize', headers: headers,
                                                         params: { answers: { content: { day: 'monday', time: '07:00', sender: 'company' } } }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to match(/Connect a dealership email/)

    get '/api/v1/plays/weekly_homes_email/performance', headers: headers
    expect(response).to have_http_status(:ok)
    expect(body['stages'].map { |s| s['key'] }).to include('subscribed', 'became_deal')
    expect(body['metrics']['recipients']).to eq(0)

    get '/api/v1/plays/weekly_homes_email/leads', headers: headers
    expect(body['meta']['total']).to eq(0)

    post '/api/v1/plays/weekly_homes_email/uninstall', headers: headers
    expect(response).to have_http_status(:ok)
    expect(Campaign.where(company_id: company.id).pluck(:status)).to eq(['archived'])
  end
end

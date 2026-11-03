# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Service issue templates', type: :request do
  let(:company) { create(:company) }
  let(:admin) { User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'D', password: 'Pass1234!', company_id: company.id, role: 'company_admin', status: 'active') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(admin)}" } }
  let!(:leak) { company.service_issue_templates.create!(title: 'Roof leak', category: 'general', complaint: 'Drips', default_pay_type: 'warranty', default_hours: 1.5, default_rate: 85) }

  def save(title, **extra)
    post '/api/v1/service-issue-templates', params: { template: { title: title, complaint: nil } }.merge(extra), headers: headers, as: :json
  end

  it 'will not overwrite a listed title without being told to' do
    save('ROOF LEAK')
    expect(response).to have_http_status(:conflict)
    expect(response.parsed_body['error']).to include('Roof leak')
    expect(leak.reload.complaint).to eq('Drips')
  end

  it 'replaces when told to' do
    save('roof leak', replace: true)
    expect(response).to have_http_status(:ok)
    expect(leak.reload.complaint).to be_nil
  end

  it 'adds a new title' do
    save('Loose railing')
    expect(response).to have_http_status(:created)
  end

  it 'sends hours and rate as numbers' do
    get '/api/v1/service-issue-templates', headers: headers
    row = response.parsed_body['templates'].find { |t| t['id'] == leak.id }
    expect(row['defaultHours']).to eq(1.5)
    expect(row['defaultRate']).to eq(85.0)
  end

  it 'shows the whole list whichever location is selected, and saves with no location' do
    other = company.locations.create!(name: 'Boise')
    get '/api/v1/service-issue-templates', headers: headers.merge('X-Location-ID' => other.id.to_s)
    expect(response.parsed_body['templates'].map { |t| t['id'] }).to include(leak.id)
    post '/api/v1/service-issue-templates', params: { template: { title: 'Anywhere' } }, headers: headers.merge('X-Location-ID' => other.id.to_s), as: :json
    expect(company.service_issue_templates.find_by(title: 'Anywhere').location_id).to be_nil
  end
end

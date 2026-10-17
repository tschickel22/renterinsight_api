# frozen_string_literal: true

require 'rails_helper'

# E69: a contractor who owns a whole project or a phase sees it in the portal,
# including phases that have no tasks yet.
RSpec.describe 'Contractor portal: owned projects and phases', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:installer) { Contractor.create!(company: company, name: 'Smith Set-Up', email: 'office@smithsetup.example', status: 'active') }
  let(:project) { company.projects.create!(name: 'Diaz home', status: 'active') }
  let!(:set_phase) { project.project_phases.create!(company: company, name: 'Set', position: 0, status: 'not_started') }
  let!(:trim_phase) { project.project_phases.create!(company: company, name: 'Trim', position: 1, status: 'not_started') }
  let(:headers) do
    token = JWT.encode({ contractor_ids: [installer.id], primary_contractor_id: installer.id, exp: 1.hour.from_now.to_i },
                       Api::Contractor::BaseController.jwt_secret, 'HS256')
    { 'Authorization' => "Bearer #{token}" }
  end

  def body = JSON.parse(response.body)

  it 'shows nothing to a contractor with no part in the project' do
    get "/api/contractor/projects/#{project.id}", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it 'shows every phase, tasks or not, to the whole-project owner' do
    project.update!(assigned_vendor_id: installer.id)

    get '/api/contractor/projects', headers: headers
    expect(body['items'].map { |p| p['id'] }).to eq([project.id])

    get "/api/contractor/projects/#{project.id}", headers: headers
    expect(body['project']['owned_by_me']).to be(true)
    expect(body['phases'].map { |p| p['name'] }).to eq(%w[Set Trim])
    expect(body['phases'].first).to include('owned_by_me' => true, 'tasks' => [])
  end

  it 'shows only the owned phase to a phase owner' do
    trim_phase.update!(assigned_vendor_id: installer.id)

    get "/api/contractor/projects/#{project.id}", headers: headers
    expect(body['phases'].map { |p| p['name'] }).to eq(['Trim'])
  end
end

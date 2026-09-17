# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Plays lead journey', type: :request do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin', status: 'active')
  end
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let(:token)   { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }
  let(:location) { company.locations.find_by(is_default: true) }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Plays::LeadResponsePlay).to receive(:texting_ready?).and_return(false)
    allow(CommunicationService).to receive(:send_email).and_return({ success: true })
    Plays::NewFacebookLead.new(company: company, user: rep, answers: { 'reps_by_location' => { location.id.to_s => [rep.id] } }).install!
  end

  def body
    JSON.parse(response.body)
  end

  it "returns a lead's place in the play and its journey" do
    lead = Lead.create!(company_id: company.id, source_id: company.sources.find_by(name: 'Facebook').id,
                        location_id: location.id, first_name: 'Tia', last_name: 'May', email: 'tia@example.com', phone: '3035551212')
    DispatchWorkflowEventsJob.new.perform
    run = WorkflowRun.where(entity_type: 'Lead', entity_id: lead.id).last
    10.times do
      break unless %w[pending running].include?(run.reload.status)
      ProcessWorkflowStepJob.perform_now(run.id)
    end

    get "/api/v1/plays/new_facebook_lead/leads/#{lead.id}", headers: headers

    expect(response).to have_http_status(:ok)
    expect(body['lead']).to include('name' => 'Tia May', 'phone' => '3035551212', 'stage' => 'waiting_for_reply')
    expect(body['events'].first).to include('kind' => 'trigger', 'title' => 'Started the play as a new lead')
    expect(body['events'].map { |e| e['title'] }).to include('Assigned to Rita Rep', 'Waiting for the lead to reply')
  end

  it 'says when a lead is not in the play' do
    lead = Lead.create!(company_id: company.id, first_name: 'Not', last_name: 'Here')

    get "/api/v1/plays/new_facebook_lead/leads/#{lead.id}", headers: headers

    expect(response).to have_http_status(:not_found)
    expect(body['error']).to eq('That lead is not in this play.')
  end
end

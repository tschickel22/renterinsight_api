# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Plays performance and leads', type: :request do
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
  end

  def body
    JSON.parse(response.body)
  end

  it 'says the play is not on' do
    get '/api/v1/plays/new_facebook_lead/performance', headers: headers

    expect(response).to have_http_status(:not_found)
    expect(body['error']).to eq('New Facebook lead is not on.')
  end

  context 'with the play on and a lead in it' do
    before do
      Plays::NewFacebookLead.new(company: company, user: rep, answers: { 'reps_by_location' => { location.id.to_s => [rep.id] } }).install!
      lead = Lead.create!(company_id: company.id, source_id: company.sources.find_by(name: 'Facebook').id,
                          location_id: location.id, first_name: 'Tia', last_name: 'May', email: 'tia@example.com')
      DispatchWorkflowEventsJob.new.perform
      run = WorkflowRun.where(entity_type: 'Lead', entity_id: lead.id).last
      10.times do
        break unless %w[pending running].include?(run.reload.status)
        ProcessWorkflowStepJob.perform_now(run.id)
      end
    end

    it 'reports stages, step counts and results' do
      get '/api/v1/plays/new_facebook_lead/performance?period=30', headers: headers

      expect(response).to have_http_status(:ok)
      expect(body['period']).to eq('30')
      expect(body['stage_counts']['waiting_for_reply']).to eq(1)
      expect(body['step_counts']).to eq('reply_wait' => 1)
      expect(body['metrics']).to include('leads_started' => 1, 'reached' => 1, 'replied' => 0)
    end

    it 'lists the leads in the play with where each one is' do
      get '/api/v1/plays/new_facebook_lead/leads?stage=waiting_for_reply', headers: headers

      expect(response).to have_http_status(:ok)
      item = body['items'].first
      expect(item).to include('name' => 'Tia May', 'source' => 'Facebook', 'rep' => 'Rita Rep',
                              'stage' => 'waiting_for_reply', 'stage_label' => 'Waiting for a reply')
      expect(item['detail_at']).to be_present
      expect(body['meta']).to include('total' => 1, 'page' => 1)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Plays::Board do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit Park #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:location) { company.locations.find_by(is_default: true) }
  let(:manager) do
    User.create!(email: "m-#{SecureRandom.hex(4)}@example.com", first_name: 'Mia', last_name: 'Manager',
                 password: 'Pass1234!', company_id: company.id, role: 'admin', status: 'active')
  end
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Plays::LeadResponsePlay).to receive(:texting_ready?).and_return(false)
    allow(CommunicationService).to receive(:send_email).and_return({ success: true })
  end

  it 'puts each person in the furthest column any of their plays has them in' do
    Plays::NewFacebookLead.new(company: company, user: manager,
                               answers: { 'reps_by_location' => { location.id.to_s => [rep.id] } }).install!
    weekly = Plays::WeeklyHomesEmail.new(company: company, user: manager, answers: {}).install!
    lead = Lead.create!(company_id: company.id, source_id: company.sources.find_by!(name: 'Facebook').id,
                        first_name: 'Tia', last_name: 'May', email: 'tia@example.com')
    DispatchWorkflowEventsJob.new.perform

    board = described_class.new(company: company).call
    expect(board[:columns].map { |c| c[:key] }).to eq(%w[new waiting follow_up weekly talking deal sold])
    expect(board[:cards].map { |c| [c[:name], c[:column], c[:play_key]] }).to eq([['Tia May', 'new', 'new_facebook_lead']])
    expect(board[:columns].find { |c| c[:key] == 'new' }[:count]).to eq(1)
    expect(board[:demo_clock]).to eq(available: false, enabled: false)

    CampaignEnrollment.create!(company_id: company.id, campaign_id: Plays::WeeklyHomesEmail.campaign_for(weekly).id,
                               recipient: lead, status: 'active', email_address_snapshot: lead.email, current_step_index: 0)

    board = described_class.new(company: company).call
    expect(board[:cards].size).to eq(1)
    expect(board[:cards].first).to include(column: 'weekly', play_key: 'weekly_homes_email', record_noun: 'lead', record_id: lead.id)
    expect(described_class.new(company: company, location_ids: [0]).call[:cards]).to eq([])
  end
end

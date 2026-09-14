# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Plays::Tracking do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:company) { Company.create!(name: "Summit Park #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:location) { company.locations.find_by(is_default: true) }
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let!(:installation) do
    Plays::NewFacebookLead.new(company: company, user: rep, answers: { 'reps_by_location' => { location.id.to_s => [rep.id] } }).install!
  end
  let(:facebook) { company.sources.find_by(name: 'Facebook') }

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(CommunicationService).to receive(:send_email).and_return({ success: true })
    allow(CommunicationService).to receive(:send_sms).and_return({ success: true })
  end

  def advance(run)
    40.times do
      run.reload
      due = %w[pending running].include?(run.status) ||
            (run.status == 'waiting' && run.wait_until.present? && run.wait_until <= Time.current)
      break unless due
      ProcessWorkflowStepJob.perform_now(run.id)
    end
    run.reload
  end

  def start_lead(name)
    lead = Lead.create!(company_id: company.id, source_id: facebook.id, location_id: location.id,
                        first_name: name, last_name: 'Test', email: "#{name.downcase}@example.com")
    DispatchWorkflowEventsJob.new.perform
    run = WorkflowRun.where(entity_type: 'Lead', entity_id: lead.id).order(:id).last
    [lead, advance(run)]
  end

  def tracking
    described_class.new(installation: installation)
  end

  it 'places each lead where it is and counts them on the map' do
    _waiting, = start_lead('Wendy')

    replied, = start_lead('Rory')
    Communication.create!(company_id: company.id, communicable: replied, channel: 'email', direction: 'inbound',
                          status: 'delivered', subject: 'Re: hi', body: 'Yes please call', to_address: 'rep@example.com',
                          from_address: replied.email)

    converted, = start_lead('Dana')
    converted.update!(is_converted: true, converted_at: Time.current)

    quiet, quiet_run = start_lead('Quinn')
    travel 25.hours do
      advance(quiet_run)
    end

    summary = tracking.summary
    expect(summary[:stage_counts]).to include('waiting_for_reply' => 1, 'replied' => 1, 'became_deal' => 1, 'follow_up' => 1)
    expect(summary[:step_counts]).to include('reply_wait' => 1, 'reply_task' => 1, 'follow_up_1' => 1)

    names = tracking.leads(stage: 'follow_up')[:items].map { |item| item[:name] }
    expect(names).to eq(['Quinn Test'])
    expect(tracking.leads(stage: 'follow_up')[:items].first[:detail]).to eq('Next: follow-up email 1 of 3')
    expect(quiet.reload.owner_id).to eq(rep.id)
  end

  it 'measures reach, replies, calls and deals' do
    replied, = start_lead('Rory')
    Communication.create!(company_id: company.id, communicable: replied, channel: 'email', direction: 'inbound',
                          status: 'delivered', subject: 'Re: hi', body: 'Call me', to_address: 'rep@example.com',
                          from_address: replied.email)
    converted, = start_lead('Dana')
    converted.update!(is_converted: true, converted_at: Time.current)
    LeadActivity.where(lead_id: converted.id, activity_type: 'call').last.update!(status: 'completed', completed_at: 10.minutes.from_now)

    metrics = tracking.summary[:metrics]

    expect(metrics).to include(leads_started: 2, reached: 2, reached_rate: 1.0, replied: 1, reply_rate: 0.5,
                               call_tasks: 2, calls_completed: 1, deals: 1, deal_rate: 0.5)
    expect(metrics[:median_minutes_to_first_message]).to be < 1
    expect(metrics[:median_minutes_to_call]).to be_within(1).of(10)
  end

  it 'counts a lead that started the play twice once, by its latest run' do
    lead, = start_lead('Tess')
    rule = WorkflowRule.find(installation.asset_ids(:workflow_rule_ids).first)
    WorkflowEngine.start_run(rule: rule, entity: lead)

    expect(tracking.summary[:metrics][:leads_started]).to eq(1)
  end
end

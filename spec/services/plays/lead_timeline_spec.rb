# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Plays::LeadTimeline do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit Park #{SecureRandom.hex(3)}", industry: 'manufactured_housing') }
  let(:location) { company.locations.find_by(is_default: true) }
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let!(:installation) do
    Plays::NewFacebookLead.new(company: company, user: rep, answers: { 'reps_by_location' => { location.id.to_s => [rep.id] } }).install!
  end
  let(:lead) do
    Lead.create!(company_id: company.id, source_id: company.sources.find_by(name: 'Facebook').id, location_id: location.id,
                 first_name: 'Tia', last_name: 'May', email: 'tia@example.com')
  end

  before do
    ActiveJob::Base.queue_adapter = :test
    allow(Plays::LeadResponsePlay).to receive(:texting_ready?).and_return(false)
    # The first email is a real Communication, so the timeline can find it and its opens.
    allow(CommunicationService).to receive(:send_email) do |args|
      Communication.create!(company_id: company.id, communicable: args[:communicable], channel: 'email', direction: 'outbound',
                            status: 'sent', subject: args[:subject], body: args[:body], to_address: args[:to],
                            from_address: 'rita@example.com', sent_at: Time.current)
    end
  end

  def run_play
    lead
    DispatchWorkflowEventsJob.new.perform
    run = WorkflowRun.where(entity_type: 'Lead', entity_id: lead.id).last
    10.times do
      break unless %w[pending running].include?(run.reload.status)
      ProcessWorkflowStepJob.perform_now(run.id)
    end
    run
  end

  def titles
    described_class.new(installation: installation, lead: lead.reload).events.map(&:title)
  end

  it 'tells the journey in order, including what the lead did' do
    run_play
    email = Communication.where(communicable: lead, direction: 'outbound', channel: 'email').last
    CommunicationEvent.create!(communication_id: email.id, event_type: 'opened', occurred_at: 5.minutes.from_now)
    Communication.create!(company_id: company.id, communicable: lead, channel: 'email', direction: 'inbound', status: 'delivered',
                          subject: 'Re: Thanks', body: 'Yes, can we see the Aurora model Saturday?', to_address: 'rita@example.com',
                          from_address: lead.email, created_at: 10.minutes.from_now)

    # Texting is off for this dealership, so the play has no text step at all.
    expect(titles).to eq([
      'Started the play as a new lead',
      'Assigned to Rita Rep',
      'First email sent',
      'Call task for Rita Rep',
      'Waiting for a reply',
      'Opened the email',
      'Replied by email'
    ])
  end

  it 'records the call once the rep makes it' do
    run_play
    LeadActivity.where(lead_id: lead.id, activity_type: 'call').last.update!(status: 'completed', completed_at: 3.minutes.from_now)

    expect(titles).to include('Call completed')
  end
end

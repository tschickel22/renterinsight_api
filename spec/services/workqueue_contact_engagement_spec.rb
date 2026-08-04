# frozen_string_literal: true

require 'rails_helper'

# The engagement_contact_* queues render Opens / Clicks / Last Engaged / Source
# columns, so normalize_contact has to carry the same engagement fields
# normalize_lead does. Contacts are only reachable through the Communication
# Center today, so the numbers come from CommunicationEvent alone.
RSpec.describe WorkqueueService, '#preload_contact_engagement', type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@x.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id)
  end
  let(:service) { described_class.new(company: company, user: user) }

  let(:contact) do
    Contact.create!(company_id: company.id, first_name: 'Jane', last_name: 'Doe',
                    email: 'jane@x.com', phone: '3035551212', owner_id: user.id)
  end

  def make_communication_for(co)
    Communication.create!(company_id: co.id, communicable: contact,
                          direction: 'outbound', channel: 'email', status: 'sent',
                          subject: 'Hi', body: 'Body',
                          from_address: 'rep@x.com', to_address: 'jane@x.com')
  end

  def make_communication
    make_communication_for(company)
  end

  def track(comm, event_type, occurred_at)
    CommunicationEvent.create!(communication: comm, event_type: event_type, occurred_at: occurred_at)
  end

  def normalized
    service.send(:preload_contact_engagement, [contact])
    service.send(:normalize_contact, contact.reload)
  end

  it 'counts opens and clicks and reports the most recent event time' do
    comm = make_communication
    track(comm, 'opened', 3.hours.ago)
    track(comm, 'opened', 2.hours.ago)
    last = 1.hour.ago
    track(comm, 'clicked', last)

    item = normalized
    expect(item[:engagement_opens]).to eq(2)
    expect(item[:engagement_clicks]).to eq(1)
    expect(item[:last_engagement_at]).to be_within(1.second).of(last)
    expect(item[:engagement_source]).to eq('Direct')
  end

  it 'ignores events older than the 7-day window' do
    comm = make_communication
    track(comm, 'opened', 8.days.ago)

    item = normalized
    expect(item[:engagement_opens]).to eq(0)
    expect(item[:last_engagement_at]).to be_nil
    expect(item[:engagement_source]).to be_nil
  end

  it 'ignores non-engagement events like sent/delivered' do
    comm = make_communication
    track(comm, 'sent', 2.hours.ago)
    track(comm, 'delivered', 2.hours.ago)

    item = normalized
    expect(item[:engagement_opens]).to eq(0)
    expect(item[:engagement_clicks]).to eq(0)
  end

  it 'does not count another company’s events' do
    other_company = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
    comm = make_communication_for(other_company)
    track(comm, 'opened', 1.hour.ago)

    expect(normalized[:engagement_opens]).to eq(0)
  end

  it 'returns zeroes rather than nil for a contact with no events' do
    item = normalized
    expect(item[:engagement_opens]).to eq(0)
    expect(item[:engagement_clicks]).to eq(0)
  end
end

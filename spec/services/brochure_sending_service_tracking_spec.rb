# frozen_string_literal: true

require 'rails_helper'

# Brochure sends used to drop the raw public URL into the email and the SMS, so
# a click was anonymous: the brochure's view_count went up and nothing else.
# Wrapping the link in a TrackedLink is what makes the open attributable to the
# person we sent it to, which is what the Workqueue queue reads.
RSpec.describe BrochureSendingService, 'click tracking', type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:brochure) do
    Brochure.create!(company_id: company.id, title: 'Fall Collection', status: 'active')
  end
  let(:lead) do
    Lead.create!(company_id: company.id, first_name: 'Jane', last_name: 'Doe', email: 'jane@x.com')
  end
  let(:communication) do
    Communication.create!(company_id: company.id, communicable: brochure,
                          direction: 'outbound', channel: 'email', status: 'sent',
                          subject: 'Hi', body: 'Body',
                          from_address: 'rep@x.com', to_address: 'jane@x.com')
  end

  let(:sent) { { email: nil, sms: nil } }

  before do
    allow(CommunicationService).to receive(:send_email) do |**kwargs|
      sent[:email] = kwargs
      { success: true, communication: communication }
    end
    allow(CommunicationService).to receive(:send_sms) do |**kwargs|
      sent[:sms] = kwargs
      { success: true, communication: communication }
    end
  end

  def share_to_lead(delivery_methods: ['email'])
    described_class.new(brochure).send(
      delivery_methods: delivery_methods,
      to_email: 'jane@x.com',
      to_phone: '3035551212',
      entity_type: 'Lead',
      entity_id: lead.id
    )
  end

  it 'mints a tracked link for the recipient and sends that link instead of the raw URL' do
    result = share_to_lead
    expect(result[:sent].size).to eq(1)

    link = TrackedLink.for_brochures.last
    expect(link.entity_type).to eq('Lead')
    expect(link.entity_id).to eq(lead.id)
    expect(link.source_id).to eq(brochure.id)
    expect(link.link_type).to eq('brochure_view')
    expect(link.redirect_url).to include("/b/#{brochure.public_id}")

    expect(sent[:email][:body]).to include("/t/#{link.token}")
    expect(sent[:email][:body]).not_to include("/b/#{brochure.public_id}")
  end

  it 'ties the link back to the communication so campaign analytics can bridge it' do
    share_to_lead
    expect(TrackedLink.for_brochures.last.communication_id).to eq(communication.id)
  end

  it 'tracks the SMS link too' do
    share_to_lead(delivery_methods: ['sms'])

    link = TrackedLink.for_brochures.last
    expect(sent[:sms][:body]).to include("/t/#{link.token}")
  end

  it 'gives email and SMS their own link so the channels stay distinguishable' do
    share_to_lead(delivery_methods: %w[email sms])

    links = TrackedLink.for_brochures.where(source_id: brochure.id)
    expect(links.count).to eq(2)
    expect(links.map(&:token).uniq.size).to eq(2)
  end

  it 'sends the plain public URL when there is nobody to attribute a click to' do
    described_class.new(brochure).send(delivery_methods: ['email'], to_email: 'someone@x.com')

    expect(TrackedLink.for_brochures.count).to eq(0)
    expect(sent[:email][:body]).to include("/b/#{brochure.public_id}")
  end

  it 'still sends if tracked link creation blows up' do
    allow(TrackedLink).to receive(:create_for_brochure!).and_raise(StandardError, 'boom')

    result = share_to_lead
    expect(result[:sent].size).to eq(1)
    expect(sent[:email][:body]).to include("/b/#{brochure.public_id}")
  end
end

# frozen_string_literal: true

require 'rails_helper'

# Events a dealer can pick in the webhook screen must actually be sent, and a
# webhook limited to some locations must not receive other locations' records.
RSpec.describe 'Webhook event wiring' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:loc_a) { Location.create!(company_id: company.id, name: 'A', code: "A-#{SecureRandom.hex(2)}", active: true) }
  let(:loc_b) { Location.create!(company_id: company.id, name: 'B', code: "B-#{SecureRandom.hex(2)}", active: true) }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }

  # Some events (location.*, agreement.expired) are sent but not offered in the
  # picker, so the list is written past the picker validation.
  def endpoint(events, location_ids: nil)
    ep = WebhookEndpoint.create!(company: company, url: 'https://example.test/hook', events: ['lead.created'],
                                 status: 'active', created_by_user_id: user.id, location_ids: location_ids)
    ep.update_columns(events: events)
    ep
  end

  def delivered(ep, event)
    WebhookDelivery.where(webhook_endpoint_id: ep.id, event: event)
  end

  before { allow(WebhookDeliveryJob).to receive(:perform_later) }

  it 'can send every event offered in the picker' do
    offered = WebhookEndpoint.available_events.map { |e| e[:value] }
    expect(offered - WebhookService::EVENTS).to eq([])
  end

  describe 'location filter' do
    it 'passes the record location, so a location-limited webhook skips other locations' do
      only_a = endpoint(['lead.created'], location_ids: [loc_a.id])
      everywhere = endpoint(['lead.created'])

      Lead.create!(company: company, source: source, first_name: 'In', last_name: 'A', location_id: loc_a.id)
      Lead.create!(company: company, source: source, first_name: 'In', last_name: 'B', location_id: loc_b.id)

      expect(delivered(only_a, 'lead.created').count).to eq(1)
      expect(delivered(only_a, 'lead.created').first.payload['location_id']).to eq(loc_a.id)
      expect(delivered(everywhere, 'lead.created').count).to eq(2)
    end

    it 'still sends records that have no location to a location-limited webhook' do
      only_a = endpoint(['lead.created'], location_ids: [loc_a.id])

      Lead.create!(company: company, source: source, first_name: 'No', last_name: 'Location')

      expect(delivered(only_a, 'lead.created').count).to eq(1)
    end

    it 'treats a location record as belonging to itself' do
      only_a = endpoint(['location.updated'], location_ids: [loc_a.id])

      loc_a.update!(name: 'A2')
      loc_b.update!(name: 'B2')

      expect(delivered(only_a, 'location.updated').count).to eq(1)
    end
  end

  describe 'agreement events' do
    let(:agreement) { company.agreements.create!(title: 'Purchase', status: 'draft', location_id: loc_a.id) }

    def add_signer(name)
      agreement.agreement_signers.create!(name: name, email: "#{name.downcase}@example.com",
                                          role: 'signer', status: 'pending')
    end

    it 'fires created, sent and signed' do
      ep = endpoint(%w[agreement.created agreement.sent agreement.signed], location_ids: [loc_a.id])

      agreement
      expect(delivered(ep, 'agreement.created').count).to eq(1)

      first = add_signer('One')
      add_signer('Two')
      expect(agreement.send_to_signers!(user)).to be(true)
      expect(delivered(ep, 'agreement.sent').count).to eq(1)

      first.sign!(signature_method: 'typed', typed_signature: 'One')
      signed = delivered(ep, 'agreement.signed')
      expect(signed.count).to eq(1)
      expect(signed.first.payload.dig('data', 'signer', 'id')).to eq(first.id)
      expect(signed.first.payload['location_id']).to eq(loc_a.id)
    end

    it 'expires without raising and sends agreement.expired once' do
      ep = endpoint(['agreement.expired'])
      add_signer('One')
      agreement.send_to_signers!(user)
      agreement.update_columns(expires_at: 1.day.ago)

      expect { ExpireAgreementsJob.perform_now }.not_to raise_error
      expect(agreement.reload.status).to eq('expired')
      expect(delivered(ep, 'agreement.expired').count).to eq(1)
    end
  end

  describe 'campaign.enrollment_completed' do
    let(:lead) { Lead.create!(company: company, source: source, first_name: 'C', last_name: 'L', email: "c-#{SecureRandom.hex(3)}@example.com") }
    let(:campaign) do
      Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                       campaign_type: 'blast', from_identity_type: 'User',
                       from_identity_id: user.id, throttle_per_day: 100)
    end

    def enrollment(metadata = {})
      CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
                                 recipient_id: lead.id, email_address_snapshot: lead.email, metadata: metadata)
    end

    it 'fires when an enrollment completes' do
      ep = endpoint(['campaign.enrollment_completed'])
      enr = enrollment
      enr.update!(status: 'completed')

      sent = delivered(ep, 'campaign.enrollment_completed')
      expect(sent.count).to eq(1)
      expect(sent.first.payload.dig('data', 'enrollment_id')).to eq(enr.id)
    end

    it 'does not fire for a test send' do
      ep = endpoint(['campaign.enrollment_completed'])
      enrollment('test_send' => 'true').update!(status: 'completed')

      expect(delivered(ep, 'campaign.enrollment_completed').count).to eq(0)
    end
  end

  describe 'endpoints holding an event that left the picker' do
    it 'can still be edited' do
      ep = endpoint(['lead.created'])
      ep.update_columns(events: %w[lead.created vehicle.archived])

      expect(ep.reload.update(events: %w[lead.created vehicle.archived lead.updated])).to be(true)
      expect(ep.update(events: %w[lead.created made.up])).to be(false)
    end
  end

  it 'sends the User-Agent from the brand kernel' do
    allow(Brand).to receive(:current).and_return(instance_double(Brand, short_name: 'Dealer Tide'))
    expect(WebhookDeliveryJob.new.send(:user_agent)).to eq('DealerTide-Webhooks/1.0')
  end
end

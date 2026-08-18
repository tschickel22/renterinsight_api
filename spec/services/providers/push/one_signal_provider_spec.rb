# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Providers::Push::OneSignalProvider do
  subject(:provider) { described_class.new(app: 'staff') }

  before do
    allow(PlatformSetting).to receive(:push).and_return(
      provider: 'onesignal',
      isEnabled: true,
      staff: { appId: 'app-123', apiKey: 'key-abc' },
      portal: { appId: 'app-456', apiKey: 'key-def' }
    )
  end

  def stub_response(code, body)
    response = instance_double(Net::HTTPResponse, body: body.to_json, code: code.to_s)
    allow(response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(code == 200)
    response
  end

  def sent_payload
    captured = nil
    allow(provider).to receive(:post) do |payload|
      captured = payload
      stub_response(200, { id: 'n-1', recipients: 1 })
    end
    yield
    captured
  end

  describe '#send_message' do
    it 'targets the external_id alias and sets the push channel' do
      payload = sent_payload do
        provider.send_message(title: 'Hi', body: 'There', external_ids: ['staff:7'])
      end

      expect(payload[:app_id]).to eq('app-123')
      expect(payload[:include_aliases]).to eq(external_id: ['staff:7'])
      expect(payload[:target_channel]).to eq('push')
      expect(payload[:headings]).to eq(en: 'Hi')
      expect(payload[:contents]).to eq(en: 'There')
    end

    it 'targets subscription ids directly when given one' do
      payload = sent_payload do
        provider.send_message(title: 'Hi', body: 'There', subscription_ids: ['player-1'])
      end

      expect(payload[:include_subscription_ids]).to eq(['player-1'])
      expect(payload).not_to have_key(:include_aliases)
    end

    it 'marks urgent notifications time-sensitive so they break through a dozing phone' do
      payload = sent_payload do
        provider.send_message(title: 'Hi', body: 'There', external_ids: ['staff:7'], priority: 'urgent')
      end

      expect(payload[:priority]).to eq(10)
      expect(payload[:ios_interruption_level]).to eq('time-sensitive')
    end

    it 'leaves normal notifications at the quieter priority' do
      payload = sent_payload do
        provider.send_message(title: 'Hi', body: 'There', external_ids: ['staff:7'], priority: 'normal')
      end

      expect(payload[:priority]).to eq(5)
      expect(payload).not_to have_key(:ios_interruption_level)
    end

    it 'passes a collapse id so repeat updates replace each other in the tray' do
      payload = sent_payload do
        provider.send_message(title: 'Hi', body: 'B', external_ids: ['staff:7'], collapse_id: 'deal:4')
      end

      expect(payload[:collapse_id]).to eq('deal:4')
    end

    it 'does not call OneSignal when there is nobody to send to' do
      expect(provider).not_to receive(:post)

      result = provider.send_message(title: 'Hi', body: 'There')
      expect(result[:success]).to be false
      expect(result[:error]).to eq('no_targets')
    end

    it 'reports invalid aliases so dead devices can be pruned' do
      allow(provider).to receive(:post).and_return(
        stub_response(200, { id: nil, recipients: 0, errors: { invalid_aliases: { external_id: ['staff:7'] } } })
      )

      result = provider.send_message(title: 'Hi', body: 'B', external_ids: ['staff:7'])

      expect(result[:success]).to be false
      expect(result[:invalid_external_ids]).to eq(['staff:7'])
    end

    it 'treats a 200 with no id as delivered-to-nobody rather than an error' do
      allow(provider).to receive(:post).and_return(stub_response(200, { id: nil, recipients: 0 }))

      result = provider.send_message(title: 'Hi', body: 'B', external_ids: ['staff:7'])

      expect(result[:success]).to be false
      expect(result[:error]).to eq('no_recipients')
    end

    it 'raises on a rejected request' do
      allow(provider).to receive(:post).and_return(stub_response(400, { errors: ['Invalid app_id'] }))

      expect {
        provider.send_message(title: 'Hi', body: 'B', external_ids: ['staff:7'])
      }.to raise_error(described_class::DeliveryError, /Invalid app_id/)
    end

    it 'raises a configuration error rather than calling out with no credentials' do
      allow(PlatformSetting).to receive(:push).and_return(
        provider: 'onesignal', isEnabled: true, staff: { appId: nil, apiKey: nil }, portal: {}
      )

      expect {
        described_class.new(app: 'staff').send_message(title: 'Hi', body: 'B', external_ids: ['staff:7'])
      }.to raise_error(described_class::ConfigurationError)
    end
  end

  describe 'per-app credentials' do
    it 'uses the portal app id for portal sends' do
      portal = described_class.new(app: 'portal')
      captured = nil
      allow(portal).to receive(:post) do |payload|
        captured = payload
        stub_response(200, { id: 'n-1', recipients: 1 })
      end

      portal.send_message(title: 'Hi', body: 'B', external_ids: ['portal:3'])

      expect(captured[:app_id]).to eq('app-456')
    end
  end
end

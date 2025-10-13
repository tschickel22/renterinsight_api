# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ProcessWebhookJob, type: :job do
  let(:lead) { create(:lead) }
  let(:communication) { create(:communication, communicable: lead, external_id: 'test-message-id') }
  
  describe '#perform' do
    context 'with Twilio webhook' do
      let(:webhook_data) do
        {
          'MessageSid' => 'test-message-id',
          'MessageStatus' => 'delivered'
        }
      end
      
      it 'processes Twilio delivery webhook' do
        expect(communication).to receive(:track_event).with('delivered', provider_data: webhook_data)
        allow(Communication).to receive(:find_by).with(external_id: 'test-message-id').and_return(communication)
        
        described_class.new.perform('twilio', webhook_data)
      end
      
      it 'processes Twilio failure webhook' do
        webhook_data['MessageStatus'] = 'failed'
        webhook_data['ErrorMessage'] = 'Invalid number'
        
        expect(communication).to receive(:track_event).with('failed', provider_data: webhook_data.merge('error' => 'Invalid number'))
        allow(Communication).to receive(:find_by).with(external_id: 'test-message-id').and_return(communication)
        
        described_class.new.perform('twilio', webhook_data)
      end
      
      it 'handles missing communication' do
        allow(Communication).to receive(:find_by).and_return(nil)
        allow(Rails.logger).to receive(:warn)
        
        expect {
          described_class.new.perform('twilio', webhook_data)
        }.not_to raise_error
        
        expect(Rails.logger).to have_received(:warn).with(match(/not found/))
      end
    end
    
    context 'with AWS SES webhook' do
      let(:webhook_data) do
        {
          'Type' => 'Notification',
          'Message' => {
            notificationType: 'Delivery',
            mail: { messageId: 'test-message-id' }
          }.to_json
        }
      end
      
      it 'processes SES delivery notification' do
        message_hash = JSON.parse(webhook_data['Message'])
        expect(communication).to receive(:track_event).with('delivered', provider_data: message_hash)
        allow(Communication).to receive(:find_by).with(external_id: 'test-message-id').and_return(communication)
        
        described_class.new.perform('aws_ses', webhook_data)
      end
      
      it 'handles subscription confirmation' do
        webhook_data['Type'] = 'SubscriptionConfirmation'
        allow(Rails.logger).to receive(:info)
        
        expect {
          described_class.new.perform('aws_ses', webhook_data)
        }.not_to raise_error
      end
    end
    
    context 'with unknown provider' do
      it 'logs warning for unknown provider' do
        allow(Rails.logger).to receive(:warn)
        
        described_class.new.perform('unknown', {})
        
        expect(Rails.logger).to have_received(:warn).with(match(/Unknown webhook provider/))
      end
    end
    
    context 'with SMTP webhook' do
      let(:webhook_data) do
        {
          'event' => 'delivered',
          'message_id' => 'test-message-id'
        }
      end
      
      it 'processes SMTP delivery event' do
        expect(communication).to receive(:track_event).with('delivered', provider_data: webhook_data)
        allow(Communication).to receive(:find_by).with(external_id: 'test-message-id').and_return(communication)
        
        described_class.new.perform('smtp', webhook_data)
      end
      
      it 'processes open event' do
        webhook_data['event'] = 'open'
        
        expect(communication).to receive(:track_event).with('opened', provider_data: webhook_data)
        allow(Communication).to receive(:find_by).with(external_id: 'test-message-id').and_return(communication)
        
        described_class.new.perform('smtp', webhook_data)
      end
      
      it 'processes click event' do
        webhook_data['event'] = 'click'
        
        expect(communication).to receive(:track_event).with('clicked', provider_data: webhook_data)
        allow(Communication).to receive(:find_by).with(external_id: 'test-message-id').and_return(communication)
        
        described_class.new.perform('smtp', webhook_data)
      end
    end
    
    it 'handles errors gracefully' do
      allow(Rails.logger).to receive(:error)
      
      expect {
        described_class.new.perform('twilio', nil)
      }.not_to raise_error
    end
  end
end

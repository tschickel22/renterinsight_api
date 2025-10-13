# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SendCommunicationJob, type: :job do
  let(:lead) { create(:lead) }
  let(:communication) { create(:communication, communicable: lead, status: 'pending') }
  
  describe '#perform' do
    it 'sends communication successfully' do
      allow(CommunicationService).to receive(:send_communication).with(communication, {}).and_return(
        { success: true, provider: 'smtp' }
      )
      
      expect {
        described_class.new.perform(communication.id)
      }.not_to raise_error
    end
    
    it 'marks communication as failed on error' do
      allow(CommunicationService).to receive(:send_communication).and_return(
        { success: false, error: 'Provider error' }
      )
      
      expect {
        described_class.new.perform(communication.id)
      }.to raise_error(StandardError, 'Provider error')
      
      communication.reload
      expect(communication.status).to eq('failed')
    end
    
    it 'skips already sent communications' do
      communication.update!(status: 'sent', sent_at: Time.current)
      
      expect(CommunicationService).not_to receive(:send_communication)
      
      described_class.new.perform(communication.id)
    end
    
    it 'handles missing communication gracefully' do
      expect {
        described_class.new.perform(99999)
      }.not_to raise_error
    end
    
    it 'logs sending' do
      allow(CommunicationService).to receive(:send_communication).and_return({ success: true, provider: 'smtp' })
      allow(Rails.logger).to receive(:info)
      
      described_class.new.perform(communication.id)
      
      expect(Rails.logger).to have_received(:info).with(match(/SendCommunicationJob: Sending communication/))
      expect(Rails.logger).to have_received(:info).with(match(/Successfully sent communication/))
    end
    
    it 'passes options to CommunicationService' do
      options = { test: 'value' }
      
      expect(CommunicationService).to receive(:send_communication).with(communication, options).and_return(
        { success: true, provider: 'smtp' }
      )
      
      described_class.new.perform(communication.id, options)
    end
  end
end

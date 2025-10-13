# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ScheduledCommunicationJob, type: :job do
  let(:lead) { create(:lead) }
  let(:communication) do
    create(:communication,
      communicable: lead,
      scheduled_status: 'scheduled',
      scheduled_for: 1.hour.from_now
    )
  end
  
  describe '#perform' do
    it 'processes scheduled communication successfully' do
      allow(SchedulingService).to receive(:process_scheduled).with(communication.id).and_return(
        { success: true }
      )
      
      expect {
        described_class.new.perform(communication.id)
      }.not_to raise_error
    end
    
    it 'raises error on failure to trigger retry' do
      allow(SchedulingService).to receive(:process_scheduled).with(communication.id).and_return(
        { success: false, error: 'Send failed' }
      )
      
      expect {
        described_class.new.perform(communication.id)
      }.to raise_error(StandardError, 'Send failed')
    end
    
    it 'handles missing communication gracefully' do
      expect {
        described_class.new.perform(99999)
      }.not_to raise_error
    end
    
    it 'logs processing' do
      allow(SchedulingService).to receive(:process_scheduled).and_return({ success: true })
      allow(Rails.logger).to receive(:info)
      
      described_class.new.perform(communication.id)
      
      expect(Rails.logger).to have_received(:info).with(match(/Processing scheduled communication/))
    end
  end
end

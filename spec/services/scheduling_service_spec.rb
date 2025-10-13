# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SchedulingService do
  let(:lead) { create(:lead) }
  let(:communication) { create(:communication, communicable: lead, status: 'pending') }
  let(:future_time) { 1.hour.from_now }
  
  describe '.schedule' do
    it 'schedules communication for future delivery' do
      allow(ScheduledCommunicationJob).to receive_message_chain(:set, :perform_later).and_return(
        double('job', job_id: 'test-job-id')
      )
      
      result = described_class.schedule(communication, send_at: future_time)
      
      expect(result[:success]).to be true
      expect(result[:scheduled_for]).to eq(future_time)
      expect(result[:job_id]).to eq('test-job-id')
      
      communication.reload
      expect(communication.scheduled_status).to eq('scheduled')
      expect(communication.scheduled_for).to be_within(1.second).of(future_time)
    end
    
    it 'raises error for past time' do
      past_time = 1.hour.ago
      
      result = described_class.schedule(communication, send_at: past_time)
      
      expect(result[:success]).to be false
      expect(result[:error]).to include('must be in the future')
    end
    
    it 'raises error for already sent communication' do
      communication.update!(status: 'sent', sent_at: Time.current)
      
      result = described_class.schedule(communication, send_at: future_time)
      
      expect(result[:success]).to be false
      expect(result[:error]).to include('already sent')
    end
    
    it 'cancels existing scheduled job when rescheduling' do
      communication.update!(
        scheduled_status: 'scheduled',
        scheduled_job_id: 'old-job-id'
      )
      
      allow(ScheduledCommunicationJob).to receive_message_chain(:set, :perform_later).and_return(
        double('job', job_id: 'new-job-id')
      )
      
      expect(described_class).to receive(:cancel_existing_job).with(communication)
      
      described_class.schedule(communication, send_at: future_time)
    end
  end
  
  describe '.cancel' do
    before do
      communication.update!(
        scheduled_status: 'scheduled',
        scheduled_for: future_time,
        scheduled_job_id: 'test-job-id'
      )
    end
    
    it 'cancels scheduled communication' do
      allow(described_class).to receive(:cancel_existing_job)
      
      result = described_class.cancel(communication)
      
      expect(result[:success]).to be true
      
      communication.reload
      expect(communication.scheduled_status).to eq('cancelled')
      expect(communication.scheduled_job_id).to be_nil
    end
    
    it 'returns error for non-scheduled communication' do
      communication.update!(scheduled_status: 'immediate')
      
      result = described_class.cancel(communication)
      
      expect(result[:success]).to be false
      expect(result[:error]).to include('not scheduled')
    end
  end
  
  describe '.reschedule' do
    let(:new_time) { 2.hours.from_now }
    
    before do
      communication.update!(
        scheduled_status: 'scheduled',
        scheduled_for: future_time,
        scheduled_job_id: 'old-job-id'
      )
    end
    
    it 'reschedules communication to new time' do
      allow(described_class).to receive(:cancel_existing_job)
      allow(ScheduledCommunicationJob).to receive_message_chain(:set, :perform_later).and_return(
        double('job', job_id: 'new-job-id')
      )
      
      result = described_class.reschedule(communication, new_time: new_time)
      
      expect(result[:success]).to be true
      expect(result[:scheduled_for]).to eq(new_time)
      
      communication.reload
      expect(communication.scheduled_for).to be_within(1.second).of(new_time)
      expect(communication.scheduled_job_id).to eq('new-job-id')
    end
    
    it 'raises error for past time' do
      result = described_class.reschedule(communication, new_time: 1.hour.ago)
      
      expect(result[:success]).to be false
      expect(result[:error]).to include('must be in the future')
    end
    
    it 'returns error for non-scheduled communication' do
      communication.update!(scheduled_status: 'immediate')
      
      result = described_class.reschedule(communication, new_time: new_time)
      
      expect(result[:success]).to be false
      expect(result[:error]).to include('not scheduled')
    end
  end
  
  describe '.process_scheduled' do
    before do
      communication.update!(
        scheduled_status: 'scheduled',
        scheduled_for: 1.minute.ago
      )
    end
    
    it 'processes scheduled communication successfully' do
      allow(CommunicationService).to receive(:send_communication).and_return(
        { success: true }
      )
      
      result = described_class.process_scheduled(communication.id)
      
      expect(result[:success]).to be true
      
      communication.reload
      expect(communication.scheduled_status).to eq('sent')
    end
    
    it 'marks as failed on send error' do
      allow(CommunicationService).to receive(:send_communication).and_return(
        { success: false, error: 'Send failed' }
      )
      
      result = described_class.process_scheduled(communication.id)
      
      communication.reload
      expect(communication.scheduled_status).to eq('failed')
    end
    
    it 'handles non-scheduled communication' do
      communication.update!(scheduled_status: 'immediate')
      
      result = described_class.process_scheduled(communication.id)
      
      expect(result[:success]).to be false
      expect(result[:error]).to include('Not scheduled')
    end
  end
  
  describe '.ready_to_send' do
    let!(:ready1) { create(:communication, communicable: lead, scheduled_status: 'scheduled', scheduled_for: 5.minutes.ago) }
    let!(:ready2) { create(:communication, communicable: lead, scheduled_status: 'scheduled', scheduled_for: 1.minute.ago) }
    let!(:future) { create(:communication, communicable: lead, scheduled_status: 'scheduled', scheduled_for: 1.hour.from_now) }
    let!(:sent) { create(:communication, communicable: lead, scheduled_status: 'sent', scheduled_for: 1.hour.ago) }
    
    it 'returns only scheduled communications ready to send' do
      ready = described_class.ready_to_send
      
      expect(ready).to include(ready1, ready2)
      expect(ready).not_to include(future, sent)
    end
    
    it 'orders by scheduled_for' do
      ready = described_class.ready_to_send
      
      expect(ready.first).to eq(ready1) # Oldest first
    end
  end
  
  describe '.upcoming' do
    let!(:upcoming1) { create(:communication, communicable: lead, scheduled_status: 'scheduled', scheduled_for: 1.hour.from_now) }
    let!(:upcoming2) { create(:communication, communicable: lead, scheduled_status: 'scheduled', scheduled_for: 2.hours.from_now) }
    let!(:past) { create(:communication, communicable: lead, scheduled_status: 'scheduled', scheduled_for: 1.hour.ago) }
    
    it 'returns future scheduled communications' do
      upcoming = described_class.upcoming(limit: 10)
      
      expect(upcoming).to include(upcoming1, upcoming2)
      expect(upcoming).not_to include(past)
    end
    
    it 'respects limit parameter' do
      10.times { create(:communication, communicable: lead, scheduled_status: 'scheduled', scheduled_for: 1.hour.from_now) }
      
      upcoming = described_class.upcoming(limit: 5)
      
      expect(upcoming.count).to eq(5)
    end
  end
  
  describe '.process_missed' do
    let!(:missed1) { create(:communication, communicable: lead, scheduled_status: 'scheduled', scheduled_for: 10.minutes.ago) }
    let!(:missed2) { create(:communication, communicable: lead, scheduled_status: 'scheduled', scheduled_for: 5.minutes.ago) }
    
    it 'processes missed scheduled communications' do
      expect(SendCommunicationJob).to receive(:perform_later).with(missed1.id)
      expect(SendCommunicationJob).to receive(:perform_later).with(missed2.id)
      
      described_class.process_missed
    end
  end
end

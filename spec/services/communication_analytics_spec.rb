# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CommunicationAnalytics do
  let(:lead) { create(:lead) }
  let(:account) { create(:account) }
  
  describe '.aggregate_stats' do
    before do
      create_list(:communication, 3, communicable: lead, channel: 'email', status: 'delivered')
      create_list(:communication, 2, communicable: lead, channel: 'sms', status: 'sent')
      create(:communication, communicable: lead, channel: 'email', status: 'failed')
    end
    
    it 'returns aggregate statistics' do
      stats = described_class.aggregate_stats
      
      expect(stats[:total]).to eq(6)
      expect(stats[:by_channel]).to include('email' => 4, 'sms' => 2)
      expect(stats[:by_status]).to include('delivered' => 3, 'sent' => 2, 'failed' => 1)
    end
    
    it 'calculates delivery rate' do
      stats = described_class.aggregate_stats
      
      expect(stats[:delivery_rate]).to be > 0
    end
    
    it 'calculates failure rate' do
      stats = described_class.aggregate_stats
      
      expect(stats[:failure_rate]).to be > 0
    end
    
    context 'with filters' do
      it 'filters by channel' do
        stats = described_class.aggregate_stats(channel: 'email')
        
        expect(stats[:total]).to eq(4)
      end
      
      it 'filters by status' do
        stats = described_class.aggregate_stats(status: 'delivered')
        
        expect(stats[:total]).to eq(3)
      end
      
      it 'filters by date range' do
        old_comm = create(:communication, communicable: lead, created_at: 2.days.ago)
        
        stats = described_class.aggregate_stats(start_date: 1.day.ago)
        
        # Should not include the old communication
        expect(stats[:total]).to eq(6)
      end
    end
  end
  
  describe '.open_rates' do
    let!(:email1) { create(:communication, communicable: lead, channel: 'email', status: 'delivered') }
    let!(:email2) { create(:communication, communicable: lead, channel: 'email', status: 'delivered') }
    let!(:email3) { create(:communication, communicable: lead, channel: 'email', status: 'delivered') }
    
    before do
      create(:communication_event, communication: email1, event_type: 'opened')
      create(:communication_event, communication: email2, event_type: 'opened')
    end
    
    it 'calculates open rate' do
      result = described_class.open_rates
      
      expect(result[:total]).to eq(3)
      expect(result[:opened]).to eq(2)
      expect(result[:rate]).to eq(66.67)
    end
    
    it 'returns zero for no emails' do
      Communication.destroy_all
      
      result = described_class.open_rates
      
      expect(result[:rate]).to eq(0)
      expect(result[:total]).to eq(0)
    end
  end
  
  describe '.click_rates' do
    let!(:email1) { create(:communication, communicable: lead, channel: 'email', status: 'delivered') }
    let!(:email2) { create(:communication, communicable: lead, channel: 'email', status: 'delivered') }
    let!(:email3) { create(:communication, communicable: lead, channel: 'email', status: 'delivered') }
    
    before do
      create(:communication_event, communication: email1, event_type: 'clicked')
    end
    
    it 'calculates click rate' do
      result = described_class.click_rates
      
      expect(result[:total]).to eq(3)
      expect(result[:clicked]).to eq(1)
      expect(result[:rate]).to eq(33.33)
    end
  end
  
  describe '.delivery_rates_by_channel' do
    before do
      create_list(:communication, 5, communicable: lead, channel: 'email', status: 'delivered')
      create_list(:communication, 2, communicable: lead, channel: 'email', status: 'failed')
      create_list(:communication, 3, communicable: lead, channel: 'sms', status: 'delivered')
      create(:communication, communicable: lead, channel: 'sms', status: 'failed')
    end
    
    it 'calculates delivery rates by channel' do
      rates = described_class.delivery_rates_by_channel
      
      email_rate = rates.find { |r| r[:channel] == 'email' }
      sms_rate = rates.find { |r| r[:channel] == 'sms' }
      
      expect(email_rate[:total]).to eq(7)
      expect(email_rate[:delivered]).to eq(5)
      expect(email_rate[:rate]).to be_within(0.01).of(71.43)
      
      expect(sms_rate[:total]).to eq(4)
      expect(sms_rate[:delivered]).to eq(3)
      expect(sms_rate[:rate]).to eq(75.0)
    end
  end
  
  describe '.volume_over_time' do
    before do
      create_list(:communication, 2, communicable: lead, created_at: Time.current)
      create_list(:communication, 3, communicable: lead, created_at: 1.day.ago)
    end
    
    it 'groups by day by default' do
      volume = described_class.volume_over_time
      
      expect(volume).to be_a(Hash)
      expect(volume.values.sum).to eq(5)
    end
    
    it 'supports different periods' do
      volume_day = described_class.volume_over_time(period: 'day')
      volume_week = described_class.volume_over_time(period: 'week')
      volume_month = described_class.volume_over_time(period: 'month')
      
      expect(volume_day).to be_a(Hash)
      expect(volume_week).to be_a(Hash)
      expect(volume_month).to be_a(Hash)
    end
  end
  
  describe '.response_time_stats' do
    let!(:inbound) { create(:communication, communicable: lead, direction: 'inbound', created_at: 1.hour.ago) }
    let!(:outbound) { create(:communication, communicable: lead, direction: 'outbound', created_at: 30.minutes.ago, communication_thread_id: inbound.communication_thread_id) }
    
    it 'calculates response time statistics' do
      stats = described_class.response_time_stats
      
      expect(stats[:average]).to be_present
      expect(stats[:median]).to be_present
      expect(stats[:total_analyzed]).to eq(1)
    end
    
    it 'returns empty hash when no data' do
      Communication.destroy_all
      
      stats = described_class.response_time_stats
      
      expect(stats).to eq({})
    end
  end
  
  describe '.template_performance' do
    let(:template) { create(:communication_template) }
    let!(:comm1) { create(:communication, communicable: lead, template: template, channel: 'email', status: 'delivered') }
    let!(:comm2) { create(:communication, communicable: lead, template: template, channel: 'email', status: 'delivered') }
    let!(:comm3) { create(:communication, communicable: lead, template: template, channel: 'email', status: 'failed') }
    
    before do
      create(:communication_event, communication: comm1, event_type: 'opened')
    end
    
    it 'returns performance stats for templates' do
      stats = described_class.template_performance
      
      expect(stats).to be_an(Array)
      expect(stats.first[:template_id]).to eq(template.id)
      expect(stats.first[:total_sent]).to eq(3)
      expect(stats.first[:delivered]).to eq(2)
      expect(stats.first[:failed]).to eq(1)
    end
  end
  
  describe '.failure_analysis' do
    before do
      create(:communication, communicable: lead, status: 'failed', channel: 'email', error_message: 'SMTP Error')
      create(:communication, communicable: lead, status: 'failed', channel: 'email', error_message: 'SMTP Error')
      create(:communication, communicable: lead, status: 'failed', channel: 'sms', error_message: 'Invalid number')
    end
    
    it 'analyzes failures' do
      analysis = described_class.failure_analysis
      
      expect(analysis[:total_failures]).to eq(3)
      expect(analysis[:by_channel]).to include('email' => 2, 'sms' => 1)
      expect(analysis[:common_errors]).to include('SMTP Error' => 2)
    end
  end
  
  describe '.scheduled_stats' do
    before do
      create_list(:communication, 2, communicable: lead, scheduled_status: 'scheduled', scheduled_for: 30.minutes.from_now)
      create(:communication, communicable: lead, scheduled_status: 'scheduled', scheduled_for: 2.days.from_now)
      create(:communication, communicable: lead, scheduled_status: 'scheduled', scheduled_for: 1.hour.ago)
    end
    
    it 'returns scheduled communication statistics' do
      stats = described_class.scheduled_stats
      
      expect(stats[:total_scheduled]).to eq(4)
      expect(stats[:upcoming_24h]).to eq(2)
      expect(stats[:overdue]).to eq(1)
    end
  end
  
  describe 'date range filters' do
    before do
      create(:communication, communicable: lead, created_at: Time.current)
      create(:communication, communicable: lead, created_at: 1.day.ago)
      create(:communication, communicable: lead, created_at: 10.days.ago)
      create(:communication, communicable: lead, created_at: 1.month.ago)
    end
    
    it 'filters by today' do
      stats = described_class.aggregate_stats(date_range: 'today')
      expect(stats[:total]).to eq(1)
    end
    
    it 'filters by last_7_days' do
      stats = described_class.aggregate_stats(date_range: 'last_7_days')
      expect(stats[:total]).to eq(2)
    end
    
    it 'filters by last_30_days' do
      stats = described_class.aggregate_stats(date_range: 'last_30_days')
      expect(stats[:total]).to eq(3)
    end
  end
end

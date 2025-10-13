require 'rails_helper'

RSpec.describe Communication, type: :model do
  # Associations
  describe 'associations' do
    it { should belong_to(:communicable) }
    it { should belong_to(:communication_thread).optional }
    it { should have_many(:communication_events).dependent(:destroy) }
  end
  
  # Validations
  describe 'validations' do
    it { should validate_presence_of(:direction) }
    it { should validate_inclusion_of(:direction).in_array(%w[outbound inbound]) }
    it { should validate_presence_of(:channel) }
    it { should validate_inclusion_of(:channel).in_array(%w[email sms portal_message]) }
    it { should validate_presence_of(:status) }
    it { should validate_inclusion_of(:status).in_array(%w[pending sent delivered failed bounced]) }
    it { should validate_presence_of(:body) }
    
    context 'email validations' do
      let(:communication) { build(:communication, channel: 'email') }
      
      it 'requires subject for email' do
        communication.subject = nil
        expect(communication).not_to be_valid
        expect(communication.errors[:subject]).to include("can't be blank for email")
      end
      
      it 'requires to_address for email' do
        communication.to_address = nil
        expect(communication).not_to be_valid
        expect(communication.errors[:to_address]).to include("can't be blank for email")
      end
      
      it 'requires from_address for email' do
        communication.from_address = nil
        expect(communication).not_to be_valid
        expect(communication.errors[:from_address]).to include("can't be blank for email")
      end
    end
    
    context 'SMS validations' do
      let(:communication) { build(:communication, channel: 'sms') }
      
      it 'requires to_address for SMS' do
        communication.to_address = nil
        expect(communication).not_to be_valid
        expect(communication.errors[:to_address]).to include("can't be blank for SMS")
      end
      
      it 'requires from_address for SMS' do
        communication.from_address = nil
        expect(communication).not_to be_valid
        expect(communication.errors[:from_address]).to include("can't be blank for SMS")
      end
    end
  end
  
  # Scopes
  describe 'scopes' do
    let!(:outbound_email) { create(:communication, direction: 'outbound', channel: 'email') }
    let!(:inbound_sms) { create(:communication, direction: 'inbound', channel: 'sms') }
    let!(:portal_message) { create(:communication, channel: 'portal_message') }
    let!(:sent_comm) { create(:communication, status: 'sent') }
    let!(:failed_comm) { create(:communication, status: 'failed') }
    
    it 'filters by direction' do
      expect(Communication.outbound).to include(outbound_email)
      expect(Communication.outbound).not_to include(inbound_sms)
      expect(Communication.inbound).to include(inbound_sms)
    end
    
    it 'filters by channel' do
      expect(Communication.email).to include(outbound_email)
      expect(Communication.sms).to include(inbound_sms)
      expect(Communication.email).not_to include(inbound_sms)
    end
    
    it 'filters by status' do
      expect(Communication.sent).to include(sent_comm)
      expect(Communication.failed).to include(failed_comm)
    end
    
    it 'orders by recent' do
      expect(Communication.recent.first.created_at).to be >= Communication.recent.last.created_at
    end
  end
  
  # Status transitions
  describe '#mark_as_sent!' do
    let(:communication) { create(:communication, status: 'pending') }
    
    it 'updates status to sent' do
      communication.mark_as_sent!
      expect(communication.status).to eq('sent')
      expect(communication.sent_at).to be_present
    end
  end
  
  describe '#mark_as_delivered!' do
    let(:communication) { create(:communication, status: 'sent') }
    
    it 'updates status to delivered' do
      communication.mark_as_delivered!
      expect(communication.status).to eq('delivered')
      expect(communication.delivered_at).to be_present
    end
  end
  
  describe '#mark_as_failed!' do
    let(:communication) { create(:communication, status: 'sent') }
    
    it 'updates status to failed with error message' do
      communication.mark_as_failed!('Network error')
      expect(communication.status).to eq('failed')
      expect(communication.failed_at).to be_present
      expect(communication.error_message).to eq('Network error')
    end
  end
  
  describe '#mark_as_bounced!' do
    let(:communication) { create(:communication, status: 'sent') }
    
    it 'updates status to bounced' do
      communication.mark_as_bounced!
      expect(communication.status).to eq('bounced')
      expect(communication.failed_at).to be_present
    end
  end
  
  # Channel checks
  describe 'channel checks' do
    it 'identifies email channel' do
      comm = build(:communication, channel: 'email')
      expect(comm.email?).to be true
      expect(comm.sms?).to be false
    end
    
    it 'identifies SMS channel' do
      comm = build(:communication, channel: 'sms')
      expect(comm.sms?).to be true
      expect(comm.email?).to be false
    end
    
    it 'identifies portal message channel' do
      comm = build(:communication, channel: 'portal_message')
      expect(comm.portal_message?).to be true
      expect(comm.email?).to be false
    end
  end
  
  # Direction checks
  describe 'direction checks' do
    it 'identifies outbound direction' do
      comm = build(:communication, direction: 'outbound')
      expect(comm.outbound?).to be true
      expect(comm.inbound?).to be false
    end
    
    it 'identifies inbound direction' do
      comm = build(:communication, direction: 'inbound')
      expect(comm.inbound?).to be true
      expect(comm.outbound?).to be false
    end
  end
  
  # Metadata helpers
  describe 'metadata helpers' do
    let(:communication) { create(:communication) }
    
    it 'adds metadata' do
      communication.add_metadata(:category, 'quotes')
      expect(communication.get_metadata(:category)).to eq('quotes')
    end
    
    it 'retrieves metadata' do
      communication.metadata = { category: 'marketing' }
      communication.save
      expect(communication.get_metadata('category')).to eq('marketing')
    end
  end
  
  # Event tracking
  describe '#track_event' do
    let(:communication) { create(:communication) }
    
    it 'creates communication event' do
      expect {
        communication.track_event('opened', { ip: '127.0.0.1' })
      }.to change(CommunicationEvent, :count).by(1)
      
      event = communication.communication_events.last
      expect(event.event_type).to eq('opened')
      expect(event.details['ip']).to eq('127.0.0.1')
    end
  end
  
  describe '#opened?' do
    let(:communication) { create(:communication) }
    
    it 'returns true when communication has open event' do
      communication.track_event('opened')
      expect(communication.opened?).to be true
    end
    
    it 'returns false when communication has no open event' do
      expect(communication.opened?).to be false
    end
  end
  
  describe '#clicked?' do
    let(:communication) { create(:communication) }
    
    it 'returns true when communication has click event' do
      communication.track_event('clicked')
      expect(communication.clicked?).to be true
    end
    
    it 'returns false when communication has no click event' do
      expect(communication.clicked?).to be false
    end
  end
  
  # Threading
  describe 'threading' do
    let(:lead) { create(:lead) }
    
    it 'assigns to thread on create' do
      communication = create(:communication, communicable: lead, channel: 'email')
      expect(communication.communication_thread).to be_present
    end
    
    it 'updates thread timestamp' do
      communication = create(:communication, communicable: lead)
      thread = communication.communication_thread
      
      expect(thread.last_message_at).to be_within(1.second).of(Time.current)
    end
    
    it 'groups communications by thread' do
      comm1 = create(:communication, communicable: lead, channel: 'email')
      comm2 = create(:communication, communicable: lead, channel: 'email')
      
      expect(comm1.communication_thread_id).to eq(comm2.communication_thread_id)
    end
  end
  
  # Polymorphic associations
  describe 'polymorphic associations' do
    it 'works with Lead' do
      lead = create(:lead)
      communication = create(:communication, communicable: lead)
      expect(communication.communicable).to eq(lead)
    end
    
    it 'works with Account' do
      account = create(:account)
      communication = create(:communication, communicable: account)
      expect(communication.communicable).to eq(account)
    end
    
    it 'works with Quote' do
      quote = create(:quote)
      communication = create(:communication, communicable: quote)
      expect(communication.communicable).to eq(quote)
    end
  end
end

# Factory for testing
FactoryBot.define do
  factory :communication do
    association :communicable, factory: :lead
    direction { 'outbound' }
    channel { 'email' }
    provider { 'smtp' }
    status { 'pending' }
    subject { 'Test Subject' }
    body { 'Test email body' }
    from_address { 'from@example.com' }
    to_address { 'to@example.com' }
    metadata { {} }
    
    trait :email do
      channel { 'email' }
      subject { 'Email Subject' }
    end
    
    trait :sms do
      channel { 'sms' }
      subject { nil }
    end
    
    trait :sent do
      status { 'sent' }
      sent_at { Time.current }
    end
    
    trait :delivered do
      status { 'delivered' }
      sent_at { 1.hour.ago }
      delivered_at { Time.current }
    end
    
    trait :failed do
      status { 'failed' }
      failed_at { Time.current }
      error_message { 'Test error' }
    end
  end
end

require 'rails_helper'

RSpec.describe CommunicationPreference, type: :model do
  # Associations
  describe 'associations' do
    it { should belong_to(:recipient) }
  end
  
  # Validations
  describe 'validations' do
    it { should validate_presence_of(:channel) }
    it { should validate_inclusion_of(:channel).in_array(%w[email sms portal_message]) }
    it { should validate_inclusion_of(:category).in_array(%w[marketing transactional quotes invoices notifications]).allow_nil }
    
    it 'validates unsubscribe_token uniqueness' do
      pref1 = create(:communication_preference)
      pref2 = build(:communication_preference, unsubscribe_token: pref1.unsubscribe_token)
      expect(pref2).not_to be_valid
    end
  end
  
  # Callbacks
  describe 'callbacks' do
    it 'generates unsubscribe_token on create' do
      preference = create(:communication_preference, unsubscribe_token: nil)
      expect(preference.unsubscribe_token).to be_present
    end
    
    it 'tracks opt_in timestamp' do
      preference = create(:communication_preference, opted_in: false)
      preference.update(opted_in: true)
      expect(preference.opted_in_at).to be_present
      expect(preference.opted_out_at).to be_nil
    end
    
    it 'tracks opt_out timestamp' do
      preference = create(:communication_preference, opted_in: true)
      preference.update(opted_in: false)
      expect(preference.opted_out_at).to be_present
    end
  end
  
  # Scopes
  describe 'scopes' do
    let!(:opted_in_email) { create(:communication_preference, channel: 'email', opted_in: true) }
    let!(:opted_out_sms) { create(:communication_preference, channel: 'sms', opted_in: false) }
    let!(:marketing_pref) { create(:communication_preference, category: 'marketing') }
    
    it 'filters opted in' do
      expect(CommunicationPreference.opted_in).to include(opted_in_email)
      expect(CommunicationPreference.opted_in).not_to include(opted_out_sms)
    end
    
    it 'filters opted out' do
      expect(CommunicationPreference.opted_out).to include(opted_out_sms)
      expect(CommunicationPreference.opted_out).not_to include(opted_in_email)
    end
    
    it 'filters by channel' do
      expect(CommunicationPreference.email).to include(opted_in_email)
      expect(CommunicationPreference.sms).to include(opted_out_sms)
    end
    
    it 'filters by category' do
      expect(CommunicationPreference.by_category('marketing')).to include(marketing_pref)
    end
  end
  
  # Class methods
  describe '.find_or_create_for' do
    let(:lead) { create(:lead) }
    
    it 'creates new preference if none exists' do
      expect {
        CommunicationPreference.find_or_create_for(
          recipient: lead,
          channel: 'email',
          category: 'marketing'
        )
      }.to change(CommunicationPreference, :count).by(1)
    end
    
    it 'finds existing preference' do
      existing = create(:communication_preference, recipient: lead, channel: 'email')
      
      result = CommunicationPreference.find_or_create_for(
        recipient: lead,
        channel: 'email'
      )
      
      expect(result.id).to eq(existing.id)
    end
  end
  
  describe '.can_send_to?' do
    let(:lead) { create(:lead) }
    
    context 'with no preference' do
      it 'allows transactional messages' do
        expect(
          CommunicationPreference.can_send_to?(
            recipient: lead,
            channel: 'email',
            category: 'transactional'
          )
        ).to be true
      end
      
      it 'allows messages with no category' do
        expect(
          CommunicationPreference.can_send_to?(
            recipient: lead,
            channel: 'email'
          )
        ).to be true
      end
    end
    
    context 'with opted in preference' do
      before do
        create(:communication_preference, recipient: lead, channel: 'email', opted_in: true)
      end
      
      it 'allows sending' do
        expect(
          CommunicationPreference.can_send_to?(
            recipient: lead,
            channel: 'email'
          )
        ).to be true
      end
    end
    
    context 'with opted out preference' do
      before do
        create(:communication_preference, recipient: lead, channel: 'email', opted_in: false)
      end
      
      it 'blocks sending' do
        expect(
          CommunicationPreference.can_send_to?(
            recipient: lead,
            channel: 'email'
          )
        ).to be false
      end
    end
  end
  
  describe '.by_token' do
    let(:preference) { create(:communication_preference) }
    
    it 'finds preference by unsubscribe token' do
      result = CommunicationPreference.by_token(preference.unsubscribe_token)
      expect(result).to eq(preference)
    end
    
    it 'returns nil for invalid token' do
      result = CommunicationPreference.by_token('invalid_token')
      expect(result).to be_nil
    end
  end
  
  # Instance methods
  describe '#opt_in!' do
    let(:preference) { create(:communication_preference, opted_in: false) }
    
    it 'opts in recipient' do
      preference.opt_in!(ip_address: '127.0.0.1')
      
      expect(preference.opted_in).to be true
      expect(preference.opted_in_at).to be_present
      expect(preference.opted_out_at).to be_nil
      expect(preference.ip_address).to eq('127.0.0.1')
    end
    
    it 'adds compliance record' do
      preference.opt_in!(ip_address: '127.0.0.1')
      
      records = preference.compliance_history
      expect(records.last['action']).to eq('opted_in')
      expect(records.last['ip_address']).to eq('127.0.0.1')
    end
  end
  
  describe '#opt_out!' do
    let(:preference) { create(:communication_preference, opted_in: true) }
    
    it 'opts out recipient' do
      preference.opt_out!('Not interested', ip_address: '127.0.0.1')
      
      expect(preference.opted_in).to be false
      expect(preference.opted_out_at).to be_present
      expect(preference.opted_out_reason).to eq('Not interested')
      expect(preference.ip_address).to eq('127.0.0.1')
    end
    
    it 'adds compliance record' do
      preference.opt_out!('Not interested', ip_address: '127.0.0.1')
      
      records = preference.compliance_history
      expect(records.last['action']).to eq('opted_out')
      expect(records.last['details']['reason']).to eq('Not interested')
    end
  end
  
  describe '#opted_in?' do
    it 'returns true when opted in' do
      preference = build(:communication_preference, opted_in: true)
      expect(preference.opted_in?).to be true
    end
    
    it 'returns false when opted out' do
      preference = build(:communication_preference, opted_in: false)
      expect(preference.opted_in?).to be false
    end
  end
  
  describe '#opted_out?' do
    it 'returns false when opted in' do
      preference = build(:communication_preference, opted_in: true)
      expect(preference.opted_out?).to be false
    end
    
    it 'returns true when opted out' do
      preference = build(:communication_preference, opted_in: false)
      expect(preference.opted_out?).to be true
    end
  end
  
  describe '#unsubscribe_url' do
    let(:preference) { create(:communication_preference) }
    
    it 'generates unsubscribe URL' do
      url = preference.unsubscribe_url('https://example.com')
      expect(url).to eq("https://example.com/unsubscribe/#{preference.unsubscribe_token}")
    end
  end
  
  describe '#can_send?' do
    it 'allows transactional messages' do
      preference = build(:communication_preference, category: 'transactional', opted_in: false)
      expect(preference.can_send?).to be true
    end
    
    it 'checks opt-in for non-transactional' do
      preference = build(:communication_preference, category: 'marketing', opted_in: true)
      expect(preference.can_send?).to be true
      
      preference.opted_in = false
      expect(preference.can_send?).to be false
    end
  end
  
  describe '#add_compliance_record' do
    let(:preference) { create(:communication_preference) }
    
    it 'adds compliance record to metadata' do
      preference.add_compliance_record('test_action', { detail: 'value' })
      
      records = preference.compliance_history
      expect(records.last['action']).to eq('test_action')
      expect(records.last['details']['detail']).to eq('value')
      expect(records.last['timestamp']).to be_present
    end
  end
  
  describe '#compliance_history' do
    let(:preference) { create(:communication_preference) }
    
    it 'returns compliance records' do
      preference.opt_in!
      preference.opt_out!('reason')
      
      history = preference.compliance_history
      expect(history.length).to eq(2)
      expect(history.first['action']).to eq('opted_in')
      expect(history.last['action']).to eq('opted_out')
    end
  end
end

# Factory for testing
FactoryBot.define do
  factory :communication_preference do
    association :recipient, factory: :lead
    channel { 'email' }
    category { nil }
    opted_in { true }
    
    trait :marketing do
      category { 'marketing' }
    end
    
    trait :transactional do
      category { 'transactional' }
    end
    
    trait :opted_out do
      opted_in { false }
      opted_out_at { Time.current }
      opted_out_reason { 'Not interested' }
    end
  end
end

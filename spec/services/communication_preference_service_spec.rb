require 'rails_helper'

RSpec.describe CommunicationPreferenceService, type: :service do
  let(:lead) { create(:lead, email: 'test@example.com') }
  
  describe '.can_send_to?' do
    context 'with no existing preference' do
      it 'allows transactional messages' do
        result = described_class.can_send_to?(
          recipient: lead,
          channel: 'email',
          category: 'transactional'
        )
        expect(result).to be true
      end
      
      it 'allows messages with no category' do
        result = described_class.can_send_to?(
          recipient: lead,
          channel: 'email'
        )
        expect(result).to be true
      end
    end
    
    context 'with opted-in preference' do
      before do
        create(:communication_preference, recipient: lead, channel: 'email', opted_in: true)
      end
      
      it 'allows sending' do
        result = described_class.can_send_to?(
          recipient: lead,
          channel: 'email'
        )
        expect(result).to be true
      end
    end
    
    context 'with opted-out preference' do
      before do
        create(:communication_preference, recipient: lead, channel: 'email', opted_in: false)
      end
      
      it 'blocks sending' do
        result = described_class.can_send_to?(
          recipient: lead,
          channel: 'email'
        )
        expect(result).to be false
      end
    end
  end
  
  describe '.opt_in' do
    it 'creates and opts in preference' do
      preference = described_class.opt_in(
        recipient: lead,
        channel: 'email',
        category: 'marketing',
        ip_address: '127.0.0.1',
        user_agent: 'Test Browser'
      )
      
      expect(preference.opted_in).to be true
      expect(preference.opted_in_at).to be_present
      expect(preference.ip_address).to eq('127.0.0.1')
      expect(preference.user_agent).to eq('Test Browser')
    end
    
    it 'updates existing opted-out preference' do
      existing = create(:communication_preference, recipient: lead, channel: 'email', opted_in: false)
      
      preference = described_class.opt_in(
        recipient: lead,
        channel: 'email',
        ip_address: '127.0.0.1'
      )
      
      expect(preference.id).to eq(existing.id)
      expect(preference.opted_in).to be true
    end
  end
  
  describe '.opt_out' do
    it 'creates and opts out preference' do
      preference = described_class.opt_out(
        recipient: lead,
        channel: 'email',
        category: 'marketing',
        reason: 'Not interested',
        ip_address: '127.0.0.1',
        user_agent: 'Test Browser'
      )
      
      expect(preference.opted_in).to be false
      expect(preference.opted_out_at).to be_present
      expect(preference.opted_out_reason).to eq('Not interested')
      expect(preference.ip_address).to eq('127.0.0.1')
    end
    
    it 'updates existing opted-in preference' do
      existing = create(:communication_preference, recipient: lead, channel: 'email', opted_in: true)
      
      preference = described_class.opt_out(
        recipient: lead,
        channel: 'email',
        reason: 'Too many emails'
      )
      
      expect(preference.id).to eq(existing.id)
      expect(preference.opted_in).to be false
      expect(preference.opted_out_reason).to eq('Too many emails')
    end
    
    it 'logs opt-out event' do
      expect(Rails.logger).to receive(:info).with(/Opt-out:/)
      
      described_class.opt_out(
        recipient: lead,
        channel: 'email',
        reason: 'Unsubscribe'
      )
    end
  end
  
  describe '.unsubscribe_by_token' do
    let!(:preference) { create(:communication_preference, recipient: lead, channel: 'email') }
    
    it 'opts out using valid token' do
      result = described_class.unsubscribe_by_token(
        token: preference.unsubscribe_token,
        reason: 'Clicked unsubscribe',
        ip_address: '127.0.0.1'
      )
      
      expect(result.opted_in).to be false
      expect(result.opted_out_reason).to eq('Clicked unsubscribe')
    end
    
    it 'raises error for invalid token' do
      expect {
        described_class.unsubscribe_by_token(token: 'invalid_token')
      }.to raise_error(CommunicationPreferenceService::Error, 'Invalid unsubscribe token')
    end
  end
  
  describe '.preferences_for' do
    before do
      create(:communication_preference, recipient: lead, channel: 'email')
      create(:communication_preference, recipient: lead, channel: 'sms')
    end
    
    it 'returns all preferences for recipient' do
      preferences = described_class.preferences_for(recipient: lead)
      expect(preferences.count).to eq(2)
    end
  end
  
  describe '.preference_for' do
    it 'finds or creates specific preference' do
      preference = described_class.preference_for(
        recipient: lead,
        channel: 'email',
        category: 'marketing'
      )
      
      expect(preference).to be_persisted
      expect(preference.channel).to eq('email')
      expect(preference.category).to eq('marketing')
    end
  end
  
  describe '.opt_out_all' do
    it 'opts out of all channels except transactional' do
      described_class.opt_out_all(
        recipient: lead,
        reason: 'Global unsubscribe',
        ip_address: '127.0.0.1'
      )
      
      # Check marketing preferences are opted out
      marketing_prefs = CommunicationPreference.where(
        recipient: lead,
        category: 'marketing'
      )
      
      expect(marketing_prefs.count).to be > 0
      expect(marketing_prefs.all?(&:opted_out?)).to be true
    end
    
    it 'does not opt out of transactional' do
      described_class.opt_out_all(recipient: lead)
      
      transactional_prefs = CommunicationPreference.where(
        recipient: lead,
        category: 'transactional'
      )
      
      expect(transactional_prefs.count).to eq(0) # Should not create transactional opt-outs
    end
  end
  
  describe '.opted_out?' do
    context 'with no opt-outs' do
      it 'returns false' do
        result = described_class.opted_out?(recipient: lead)
        expect(result).to be false
      end
    end
    
    context 'with channel opt-out' do
      before do
        create(:communication_preference, recipient: lead, channel: 'email', opted_in: false)
      end
      
      it 'returns true for email channel' do
        result = described_class.opted_out?(recipient: lead, channel: 'email')
        expect(result).to be true
      end
      
      it 'returns false for SMS channel' do
        result = described_class.opted_out?(recipient: lead, channel: 'sms')
        expect(result).to be false
      end
    end
    
    context 'with category opt-out' do
      before do
        create(:communication_preference, 
          recipient: lead, 
          channel: 'email', 
          category: 'marketing', 
          opted_in: false
        )
      end
      
      it 'returns true for marketing category' do
        result = described_class.opted_out?(
          recipient: lead, 
          channel: 'email', 
          category: 'marketing'
        )
        expect(result).to be true
      end
      
      it 'returns false for quotes category' do
        result = described_class.opted_out?(
          recipient: lead, 
          channel: 'email', 
          category: 'quotes'
        )
        expect(result).to be false
      end
    end
  end
  
  describe '.compliance_report' do
    let!(:email_pref) { create(:communication_preference, recipient: lead, channel: 'email') }
    let!(:sms_pref) { create(:communication_preference, recipient: lead, channel: 'sms', opted_in: false) }
    let!(:communication) { create(:communication, communicable: lead, direction: 'outbound') }
    
    before do
      email_pref.opt_out!('Not interested', ip_address: '127.0.0.1')
    end
    
    it 'generates compliance report' do
      report = described_class.compliance_report(recipient: lead)
      
      expect(report[:recipient_type]).to eq('Lead')
      expect(report[:recipient_id]).to eq(lead.id)
      expect(report[:preferences].count).to eq(2)
      expect(report[:total_communications_sent]).to eq(1)
      expect(report[:generated_at]).to be_present
    end
    
    it 'includes preference details' do
      report = described_class.compliance_report(recipient: lead)
      
      email_pref_data = report[:preferences].find { |p| p[:channel] == 'email' }
      expect(email_pref_data[:opted_in]).to be false
      expect(email_pref_data[:opted_out_reason]).to eq('Not interested')
      expect(email_pref_data[:compliance_history]).to be_present
    end
  end
  
  describe '.handle_bounce' do
    let(:communication) { create(:communication, communicable: lead, channel: 'email') }
    
    context 'with hard bounce' do
      it 'automatically opts out recipient' do
        described_class.handle_bounce(
          communication: communication,
          bounce_type: 'hard',
          reason: 'Mailbox does not exist'
        )
        
        preference = CommunicationPreference.find_by(
          recipient: lead,
          channel: 'email'
        )
        
        expect(preference.opted_in).to be false
        expect(preference.opted_out_reason).to include('Hard bounce')
      end
      
      it 'logs warning' do
        expect(Rails.logger).to receive(:warn).with(/Auto opt-out due to hard bounce/)
        
        described_class.handle_bounce(
          communication: communication,
          bounce_type: 'hard'
        )
      end
    end
    
    context 'with soft bounce' do
      it 'does not opt out recipient' do
        expect {
          described_class.handle_bounce(
            communication: communication,
            bounce_type: 'soft'
          )
        }.not_to change { CommunicationPreference.where(recipient: lead).count }
      end
    end
  end
  
  describe '.handle_spam_complaint' do
    let(:communication) { create(:communication, communicable: lead, channel: 'email') }
    
    it 'opts out of marketing' do
      described_class.handle_spam_complaint(communication: communication)
      
      preference = CommunicationPreference.find_by(
        recipient: lead,
        channel: 'email',
        category: 'marketing'
      )
      
      expect(preference.opted_in).to be false
      expect(preference.opted_out_reason).to eq('Spam complaint')
    end
    
    it 'logs warning' do
      expect(Rails.logger).to receive(:warn).with(/Opt-out due to spam complaint/)
      
      described_class.handle_spam_complaint(communication: communication)
    end
  end
  
  describe '.unsubscribe_url' do
    it 'generates unsubscribe URL' do
      url = described_class.unsubscribe_url(
        recipient: lead,
        channel: 'email',
        base_url: 'https://example.com'
      )
      
      expect(url).to include('https://example.com/unsubscribe/')
      expect(url).to include(CommunicationPreference.find_by(recipient: lead).unsubscribe_token)
    end
    
    it 'uses default base URL from environment' do
      ENV['APP_BASE_URL'] = 'https://app.platformdms.com'
      
      url = described_class.unsubscribe_url(
        recipient: lead,
        channel: 'email'
      )
      
      expect(url).to include('https://app.platformdms.com')
      
      ENV['APP_BASE_URL'] = nil
    end
  end
  
  describe '.add_unsubscribe_footer' do
    let(:unsubscribe_url) { 'https://example.com/unsubscribe/abc123' }
    
    context 'with plain text email' do
      let(:body) { "Hello,\n\nThis is a test email." }
      
      it 'adds plain text footer' do
        result = described_class.add_unsubscribe_footer(
          body: body,
          unsubscribe_url: unsubscribe_url
        )
        
        expect(result).to include('To unsubscribe')
        expect(result).to include(unsubscribe_url)
      end
    end
    
    context 'with HTML email' do
      let(:body) { '<html><body><p>Test email</p></body></html>' }
      
      it 'adds HTML footer' do
        result = described_class.add_unsubscribe_footer(
          body: body,
          unsubscribe_url: unsubscribe_url
        )
        
        expect(result).to include('<a href=')
        expect(result).to include(unsubscribe_url)
        expect(result).to include('click here')
      end
    end
  end
end

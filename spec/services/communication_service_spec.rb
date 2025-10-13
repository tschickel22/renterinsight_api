require 'rails_helper'

RSpec.describe CommunicationService, type: :service do
  let(:lead) { create(:lead, email: 'test@example.com', phone: '+11234567890') }
  let(:quote) { create(:quote, lead: lead) }
  
  describe '.send_communication' do
    context 'with opted-in recipient' do
      before do
        allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(true)
      end
      
      it 'creates communication record' do
        allow_any_instance_of(Providers::Email::SmtpProvider).to receive(:send_message)
          .and_return({ success: true, external_id: 'msg_123' })
        
        expect {
          CommunicationService.send_communication(
            communicable: lead,
            channel: 'email',
            to: 'test@example.com',
            subject: 'Test',
            body: 'Test body'
          )
        }.to change(Communication, :count).by(1)
      end
      
      it 'sets communication attributes correctly' do
        allow_any_instance_of(Providers::Email::SmtpProvider).to receive(:send_message)
          .and_return({ success: true, external_id: 'msg_123' })
        
        communication = CommunicationService.send_communication(
          communicable: lead,
          channel: 'email',
          direction: 'outbound',
          to: 'test@example.com',
          from: 'from@example.com',
          subject: 'Test',
          body: 'Test body',
          category: 'marketing',
          provider: :smtp
        )
        
        expect(communication.communicable).to eq(lead)
        expect(communication.channel).to eq('email')
        expect(communication.direction).to eq('outbound')
        expect(communication.to_address).to eq('test@example.com')
        expect(communication.from_address).to eq('from@example.com')
        expect(communication.subject).to eq('Test')
        expect(communication.body).to eq('Test body')
        expect(communication.provider).to eq('smtp')
      end
      
      it 'tracks send event' do
        allow_any_instance_of(Providers::Email::SmtpProvider).to receive(:send_message)
          .and_return({ success: true, external_id: 'msg_123' })
        
        communication = CommunicationService.send_communication(
          communicable: lead,
          channel: 'email',
          to: 'test@example.com',
          subject: 'Test',
          body: 'Test body'
        )
        
        expect(communication.communication_events.count).to eq(1)
        expect(communication.communication_events.first.event_type).to eq('sent')
      end
      
      it 'updates external_id from provider' do
        allow_any_instance_of(Providers::Email::SmtpProvider).to receive(:send_message)
          .and_return({ success: true, external_id: 'msg_456' })
        
        communication = CommunicationService.send_communication(
          communicable: lead,
          channel: 'email',
          to: 'test@example.com',
          subject: 'Test',
          body: 'Test body'
        )
        
        expect(communication.external_id).to eq('msg_456')
      end
    end
    
    context 'with opted-out recipient' do
      before do
        allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(false)
      end
      
      it 'raises OptOutError' do
        expect {
          CommunicationService.send_communication(
            communicable: lead,
            channel: 'email',
            to: 'test@example.com',
            subject: 'Test',
            body: 'Test body',
            category: 'marketing'
          )
        }.to raise_error(CommunicationService::OptOutError)
      end
    end
    
    context 'with provider failure' do
      before do
        allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(true)
        allow_any_instance_of(Providers::Email::SmtpProvider).to receive(:send_message)
          .and_raise(Providers::BaseProvider::SendError, 'Network error')
      end
      
      it 'marks communication as failed' do
        expect {
          CommunicationService.send_communication(
            communicable: lead,
            channel: 'email',
            to: 'test@example.com',
            subject: 'Test',
            body: 'Test body'
          )
        }.to raise_error(CommunicationService::ProviderError)
        
        communication = Communication.last
        expect(communication.status).to eq('failed')
        expect(communication.error_message).to be_present
      end
    end
  end
  
  describe '.send_email' do
    before do
      allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(true)
      allow_any_instance_of(Providers::Email::SmtpProvider).to receive(:send_message)
        .and_return({ success: true, external_id: 'msg_123' })
    end
    
    it 'sends email communication' do
      communication = CommunicationService.send_email(
        communicable: lead,
        to: 'test@example.com',
        subject: 'Test Email',
        body: 'Email body'
      )
      
      expect(communication.channel).to eq('email')
      expect(communication.subject).to eq('Test Email')
    end
  end
  
  describe '.send_sms' do
    before do
      allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(true)
      allow_any_instance_of(Providers::Sms::TwilioProvider).to receive(:send_message)
        .and_return({ success: true, external_id: 'sms_123' })
    end
    
    it 'sends SMS communication' do
      communication = CommunicationService.send_sms(
        communicable: lead,
        to: '+11234567890',
        body: 'SMS body'
      )
      
      expect(communication.channel).to eq('sms')
      expect(communication.body).to eq('SMS body')
    end
  end
  
  describe '.send_portal_message' do
    before do
      allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(true)
    end
    
    it 'sends portal message with portal_visible=true' do
      communication = CommunicationService.send_portal_message(
        communicable: lead,
        to: 'test@example.com',
        body: 'Portal message'
      )
      
      expect(communication.channel).to eq('portal_message')
      expect(communication.portal_visible).to be true
    end
  end
  
  describe '.send_quote_email' do
    before do
      allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(true)
      allow_any_instance_of(Providers::Email::SmtpProvider).to receive(:send_message)
        .and_return({ success: true, external_id: 'msg_123' })
    end
    
    it 'sends quote email with quote metadata' do
      communication = CommunicationService.send_quote_email(
        quote: quote,
        to: 'test@example.com',
        subject: 'Your Quote',
        body: 'Quote details'
      )
      
      expect(communication.metadata['quote_id']).to eq(quote.id)
      expect(communication.metadata['category']).to eq('quotes')
      expect(communication.metadata['via']).to eq('quote_email_service')
    end
  end
  
  describe 'provider switching' do
    before do
      allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(true)
    end
    
    context 'with SMTP provider' do
      it 'uses SmtpProvider' do
        expect_any_instance_of(Providers::Email::SmtpProvider).to receive(:send_message)
          .and_return({ success: true, external_id: 'msg_123' })
        
        CommunicationService.send_email(
          communicable: lead,
          to: 'test@example.com',
          subject: 'Test',
          body: 'Body',
          provider: :smtp
        )
      end
    end
    
    context 'with Gmail Relay provider' do
      it 'uses GmailRelayProvider' do
        expect_any_instance_of(Providers::Email::GmailRelayProvider).to receive(:send_message)
          .and_return({ success: true, external_id: 'msg_123' })
        
        CommunicationService.send_email(
          communicable: lead,
          to: 'test@example.com',
          subject: 'Test',
          body: 'Body',
          provider: :gmail_relay
        )
      end
    end
    
    context 'with AWS SES provider' do
      it 'uses AwsSesProvider' do
        expect_any_instance_of(Providers::Email::AwsSesProvider).to receive(:send_message)
          .and_return({ success: true, external_id: 'msg_123' })
        
        CommunicationService.send_email(
          communicable: lead,
          to: 'test@example.com',
          subject: 'Test',
          body: 'Body',
          provider: :aws_ses
        )
      end
    end
    
    context 'with Twilio provider' do
      it 'uses TwilioProvider' do
        expect_any_instance_of(Providers::Sms::TwilioProvider).to receive(:send_message)
          .and_return({ success: true, external_id: 'sms_123' })
        
        CommunicationService.send_sms(
          communicable: lead,
          to: '+11234567890',
          body: 'SMS body',
          provider: :twilio
        )
      end
    end
    
    context 'with unknown provider' do
      it 'raises ProviderError' do
        expect {
          CommunicationService.send_email(
            communicable: lead,
            to: 'test@example.com',
            subject: 'Test',
            body: 'Body',
            provider: :unknown_provider
          )
        }.to raise_error(CommunicationService::ProviderError, /Unknown email provider/)
      end
    end
  end
  
  describe '#can_send_to_recipient?' do
    let(:service) { CommunicationService.new }
    
    it 'delegates to CommunicationPreferenceService' do
      expect(CommunicationPreferenceService).to receive(:can_send_to?)
        .with(recipient: lead, channel: 'email', category: 'marketing')
        .and_return(true)
      
      result = service.can_send_to_recipient?(
        recipient: lead,
        channel: 'email',
        category: 'marketing'
      )
      
      expect(result).to be true
    end
  end
  
  describe 'default provider selection' do
    it 'uses SMTP by default for email' do
      ENV['DEFAULT_EMAIL_PROVIDER'] = nil
      allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(true)
      
      expect_any_instance_of(Providers::Email::SmtpProvider).to receive(:send_message)
        .and_return({ success: true, external_id: 'msg_123' })
      
      CommunicationService.send_email(
        communicable: lead,
        to: 'test@example.com',
        subject: 'Test',
        body: 'Body'
      )
    end
    
    it 'respects DEFAULT_EMAIL_PROVIDER env variable' do
      ENV['DEFAULT_EMAIL_PROVIDER'] = 'aws_ses'
      allow(CommunicationPreferenceService).to receive(:can_send_to?).and_return(true)
      
      expect_any_instance_of(Providers::Email::AwsSesProvider).to receive(:send_message)
        .and_return({ success: true, external_id: 'msg_123' })
      
      CommunicationService.send_email(
        communicable: lead,
        to: 'test@example.com',
        subject: 'Test',
        body: 'Body'
      )
      
      ENV['DEFAULT_EMAIL_PROVIDER'] = nil
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe BuyerPortalService do
  let(:company) { Company.create!(name: 'Test Company') }
  let(:source) { Source.create!(name: 'Test Source', source_type: 'website', is_active: true) }
  let(:lead) do
    Lead.create!(
      first_name: 'John',
      last_name: 'Doe',
      email: 'john@example.com',
      phone: '555-1234',
      source: source,
      company: company,
      is_converted: true
    )
  end
  let(:account) do
    Account.create!(
      company: company,
      name: 'John Doe Account',
      email: 'john@example.com',
      status: 'active'
    )
  end
  
  before do
    lead.update!(converted_account_id: account.id)
  end

  describe '.create_portal_access' do
    it 'creates portal access with default settings' do
      portal_access = described_class.create_portal_access(lead, 'john@example.com', send_welcome: false)

      expect(portal_access).to be_persisted
      expect(portal_access.buyer).to eq(lead)
      expect(portal_access.email).to eq('john@example.com')
      expect(portal_access.portal_enabled).to be true
      expect(portal_access.email_opt_in).to be true
      expect(portal_access.sms_opt_in).to be false
      expect(portal_access.marketing_opt_in).to be false
      expect(portal_access.password_digest).to be_present # Password was auto-generated
    end

    it 'sends welcome email when send_welcome is true', :skip_email do
      expect(BuyerPortalMailer).to receive(:welcome_email).and_call_original
      
      portal_access = described_class.create_portal_access(lead, 'john@example.com', send_welcome: true)

      expect(portal_access).to be_persisted
    end

    it 'creates Communication record when sending welcome email', :skip_email do
      portal_access = described_class.create_portal_access(lead, 'john@example.com', send_welcome: true)

      communication = Communication.where(
        communicable: lead,
        metadata: { email_type: 'welcome' }
      ).last

      expect(communication).to be_present
      expect(communication.direction).to eq('outbound')
      expect(communication.channel).to eq('email')
      expect(communication.status).to eq('sent')
      expect(communication.portal_visible).to be false
    end
  end

  describe '.send_welcome_email' do
    let(:portal_access) do
      BuyerPortalAccess.create!(
        buyer: lead,
        email: 'john@example.com',
        password: 'Password123!',
        password_confirmation: 'Password123!',
        portal_enabled: true
      )
    end

    it 'sends welcome email and creates Communication record', :skip_email do
      expect do
        communication = described_class.send_welcome_email(portal_access)
        expect(communication).to be_a(Communication)
        expect(communication.status).to eq('sent')
      end.to change(Communication, :count).by(1)
    end

    it 'logs welcome email sending', :skip_email do
      expect(Rails.logger).to receive(:info).with(/Welcome email sent to/)
      described_class.send_welcome_email(portal_access)
    end
  end

  describe '.send_magic_link_email' do
    let(:portal_access) do
      BuyerPortalAccess.create!(
        buyer: lead,
        email: 'john@example.com',
        password: 'Password123!',
        password_confirmation: 'Password123!',
        portal_enabled: true
      )
    end

    it 'generates login token before sending', :skip_email do
      described_class.send_magic_link_email(portal_access)
      portal_access.reload

      expect(portal_access.login_token).to be_present
      expect(portal_access.login_token_expires_at).to be_present
      expect(portal_access.login_token_expires_at).to be > Time.current
    end

    it 'sends magic link email and creates Communication record', :skip_email do
      expect do
        communication = described_class.send_magic_link_email(portal_access)
        expect(communication).to be_a(Communication)
        expect(communication.metadata[:email_type]).to eq('magic_link')
      end.to change(Communication, :count).by(1)
    end

    it 'includes token expiration in metadata', :skip_email do
      communication = described_class.send_magic_link_email(portal_access)

      expect(communication.metadata[:token_expires_at]).to be_present
    end
  end

  describe '.send_password_reset_email' do
    let(:portal_access) do
      BuyerPortalAccess.create!(
        buyer: lead,
        email: 'john@example.com',
        password: 'OldPassword123!',
        password_confirmation: 'OldPassword123!',
        portal_enabled: true
      )
    end

    it 'generates reset token before sending', :skip_email do
      described_class.send_password_reset_email(portal_access)
      portal_access.reload

      expect(portal_access.reset_token).to be_present
      expect(portal_access.reset_token_expires_at).to be_present
      expect(portal_access.reset_token_expires_at).to be > Time.current
    end

    it 'sends password reset email and creates Communication record', :skip_email do
      expect do
        communication = described_class.send_password_reset_email(portal_access)
        expect(communication).to be_a(Communication)
        expect(communication.metadata[:email_type]).to eq('password_reset')
      end.to change(Communication, :count).by(1)
    end
  end

  describe '.send_quote_acceptance_email' do
    let(:portal_access) do
      BuyerPortalAccess.create!(
        buyer: lead,
        email: 'john@example.com',
        password: 'Password123!',
        password_confirmation: 'Password123!',
        portal_enabled: true
      )
    end
    
    let(:quote) do
      Quote.create!(
        account: account,
        quote_number: 'Q-2025-001',
        status: 'accepted',
        subtotal: 1000.00,
        tax: 100.00,
        total: 1100.00,
        valid_until: 30.days.from_now
      )
    end

    it 'sends quote acceptance email and creates Communication record', :skip_email do
      expect do
        communication = described_class.send_quote_acceptance_email(quote, portal_access)
        expect(communication).to be_a(Communication)
        expect(communication.communicable).to eq(quote)
        expect(communication.portal_visible).to be true
      end.to change(Communication, :count).by(1)
    end

    it 'includes quote details in metadata', :skip_email do
      communication = described_class.send_quote_acceptance_email(quote, portal_access)

      expect(communication.metadata[:email_type]).to eq('quote_acceptance')
      expect(communication.metadata[:quote_number]).to eq('Q-2025-001')
      expect(communication.metadata[:quote_total]).to eq(1100.00)
    end
  end

  describe '.notify_quote_rejection' do
    let(:portal_access) do
      BuyerPortalAccess.create!(
        buyer: lead,
        email: 'john@example.com',
        password: 'Password123!',
        password_confirmation: 'Password123!',
        portal_enabled: true
      )
    end
    
    let(:quote) do
      Quote.create!(
        account: account,
        quote_number: 'Q-2025-002',
        status: 'rejected',
        subtotal: 2000.00,
        tax: 200.00,
        total: 2200.00,
        valid_until: 30.days.from_now
      )
    end

    it 'sends internal notification and creates Communication record', :skip_email do
      expect do
        communication = described_class.notify_quote_rejection(quote, portal_access)
        expect(communication).to be_a(Communication)
        expect(communication.communicable).to eq(quote)
        expect(communication.portal_visible).to be false
      end.to change(Communication, :count).by(1)
    end

    it 'sends to internal sales email', :skip_email do
      communication = described_class.notify_quote_rejection(quote, portal_access)

      expect(communication.to_address).to eq(ENV.fetch('SALES_EMAIL', 'sales@renterinsight.com'))
    end

    it 'includes rejection details in metadata', :skip_email do
      communication = described_class.notify_quote_rejection(quote, portal_access)

      expect(communication.metadata[:email_type]).to eq('quote_rejection_internal')
      expect(communication.metadata[:rejected_by]).to eq('john@example.com')
    end
  end

  describe '.notify_internal_of_reply' do
    let(:portal_access) do
      BuyerPortalAccess.create!(
        buyer: lead,
        email: 'john@example.com',
        password: 'Password123!',
        password_confirmation: 'Password123!',
        portal_enabled: true
      )
    end
    
    let(:thread) do
      CommunicationThread.create!(
        participant_type: 'Lead',
        participant_id: lead.id,
        channel: 'portal_message',
        subject: 'Question about service',
        status: 'active'
      )
    end
    
    let(:buyer_message) do
      Communication.create!(
        communicable: lead,
        communication_thread: thread,
        direction: 'inbound',
        channel: 'portal_message',
        status: 'sent',
        subject: 'Question',
        body: 'I have a question about the quote you sent me.',
        to_address: 'support@renterinsight.com',
        from_address: 'john@example.com',
        portal_visible: true
      )
    end

    it 'sends internal notification and creates Communication record', :skip_email do
      expect do
        communication = described_class.notify_internal_of_reply(buyer_message)
        expect(communication).to be_a(Communication)
        expect(communication.portal_visible).to be false
      end.to change(Communication, :count).by(1)
    end

    it 'sends to support email', :skip_email do
      communication = described_class.notify_internal_of_reply(buyer_message)

      expect(communication.to_address).to eq(ENV.fetch('SUPPORT_EMAIL', 'support@renterinsight.com'))
    end

    it 'includes thread details in metadata', :skip_email do
      communication = described_class.notify_internal_of_reply(buyer_message)

      expect(communication.metadata[:email_type]).to eq('reply_notification_internal')
      expect(communication.metadata[:original_communication_id]).to eq(buyer_message.id)
      expect(communication.metadata[:thread_id]).to eq(thread.id)
    end

    it 'logs notification sending', :skip_email do
      expect(Rails.logger).to receive(:info).with(/Reply notification sent for thread/)
      described_class.notify_internal_of_reply(buyer_message)
    end
  end
end

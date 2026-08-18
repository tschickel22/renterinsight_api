# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PortalPushService do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:buyer) do
    Contact.create!(company_id: company.id, first_name: 'Dana', last_name: 'Buyer',
                    email: "dana-#{SecureRandom.hex(3)}@example.com")
  end
  let!(:access) do
    BuyerPortalAccess.create!(buyer: buyer, company_id: company.id, email: buyer.email,
                              password: 'Password123!', password_confirmation: 'Password123!')
  end

  describe '.document_to_sign' do
    let(:agreement) do
      instance_double(Agreement, id: 42, company_id: company.id, company: company, title: 'Purchase Agreement')
    end
    let(:signer) { instance_double(AgreementSigner, id: 7, email: buyer.email) }

    it 'finds the signer\'s portal login by email and pushes a signing request' do
      expect(PushNotificationService).to receive(:notify_portal).with(
        hash_including(
          buyer_access: access,
          event: 'document_to_sign',
          path: 'agreements/42',
          priority: 'high'
        )
      ).and_return(true)

      expect(described_class.document_to_sign(agreement: agreement, signer: signer)).to be true
    end

    it 'names the dealership, not the platform, in the message' do
      captured = nil
      allow(PushNotificationService).to receive(:notify_portal) { |args| captured = args; true }

      described_class.document_to_sign(agreement: agreement, signer: signer)

      expect(captured[:body]).to include(company.name)
    end

    it 'does nothing when the signer has no portal login' do
      other = instance_double(AgreementSigner, id: 8, email: 'nobody@example.com')

      expect(PushNotificationService).not_to receive(:notify_portal)
      expect(described_class.document_to_sign(agreement: agreement, signer: other)).to be false
    end

    it 'shares a collapse key with its reminder, so the reminder replaces it in the tray' do
      keys = []
      allow(PushNotificationService).to receive(:notify_portal) { |args| keys << args[:collapse_key]; true }

      described_class.document_to_sign(agreement: agreement, signer: signer)
      described_class.document_signature_reminder(agreement: agreement, signer: signer)

      expect(keys.uniq.length).to eq(1)
    end

    it 'swallows a push failure rather than taking down the email it rides alongside' do
      allow(PushNotificationService).to receive(:notify_portal).and_raise(StandardError, 'OneSignal down')

      expect(described_class.document_to_sign(agreement: agreement, signer: signer)).to be false
    end
  end

  describe '.new_invoice' do
    let(:invoice) do
      instance_double(Invoice, id: 5, company_id: company.id, company: company,
                               invoice_number: 'INV-1001', total: 2500.0, contact: buyer)
    end

    it 'pushes the invoice with its amount and deep links to the invoices page' do
      captured = nil
      allow(PushNotificationService).to receive(:notify_portal) { |args| captured = args; true }

      described_class.new_invoice(invoice: invoice)

      expect(captured[:event]).to eq('invoice_created')
      expect(captured[:path]).to eq('invoices')
      expect(captured[:body]).to include('INV-1001')
      expect(captured[:body]).to include('$2,500.00')
    end
  end

  describe '.new_message' do
    let(:communication) do
      instance_double(Communication, id: 3, company: company, communicable: buyer,
                                     body: '<p>Your home is ready for   walkthrough</p>')
    end

    it 'strips markup and collapses whitespace in the preview' do
      captured = nil
      allow(PushNotificationService).to receive(:notify_portal) { |args| captured = args; true }

      described_class.new_message(communication: communication)

      expect(captured[:body]).to eq('Your home is ready for walkthrough')
    end
  end
end

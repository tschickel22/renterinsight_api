# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ImapSentEmailService do
  describe '.already_logged?' do
    let(:company) { create(:company) }
    let(:lead) { create(:lead, company: company, email: 'buyer@example.com') }
    let(:message_id) { 'abc123_def456@srv-example.mail' }

    context 'when the platform already sent and logged the email' do
      # This is the regression: the CRM sends, writes the RFC Message-ID to
      # external_id, and the sync job later reads the same message out of the
      # Sent folder. Before the fix it had no way to see the platform's record.
      it 'matches on external_id' do
        create(:communication, :sent,
               communicable: lead,
               company_id: company.id,
               to_address: lead.email,
               external_id: message_id)

        expect(described_class.already_logged?(message_id: message_id)).to be true
      end
    end

    context 'when a previous sync logged the email' do
      it 'matches on metadata imap_message_id' do
        create(:communication, :sent,
               communicable: lead,
               company_id: company.id,
               to_address: lead.email,
               metadata: { 'source' => 'imap_sync', 'imap_message_id' => message_id })

        expect(described_class.already_logged?(message_id: message_id)).to be true
      end

      it 'matches on metadata internet_message_id from the Graph path' do
        create(:communication, :sent,
               communicable: lead,
               company_id: company.id,
               to_address: lead.email,
               metadata: { 'source' => 'graph_sync', 'internet_message_id' => message_id })

        expect(described_class.already_logged?(message_id: message_id)).to be true
      end
    end

    context 'when the message is genuinely new' do
      it 'returns false' do
        expect(described_class.already_logged?(message_id: message_id)).to be false
      end

      it 'does not match a different Message-ID' do
        create(:communication, :sent,
               communicable: lead,
               company_id: company.id,
               to_address: lead.email,
               external_id: 'some_other_id@srv-example.mail')

        expect(described_class.already_logged?(message_id: message_id)).to be false
      end
    end

    context 'timestamp fallback, for sends whose Message-ID never reached external_id' do
      let(:sent_at) { Time.current }

      it 'matches an outbound email to the same recipient within the window' do
        create(:communication, :sent,
               communicable: lead,
               company_id: company.id,
               to_address: lead.email,
               sent_at: sent_at)

        expect(described_class.already_logged?(
          message_id: nil, communicable: lead, to_address: lead.email, sent_at: sent_at + 5.seconds
        )).to be true
      end

      it 'does not match outside the window' do
        create(:communication, :sent,
               communicable: lead,
               company_id: company.id,
               to_address: lead.email,
               sent_at: sent_at)

        expect(described_class.already_logged?(
          message_id: nil, communicable: lead, to_address: lead.email, sent_at: sent_at + 5.minutes
        )).to be false
      end

      it 'does not match an inbound reply sitting in the same window' do
        create(:communication, :inbound,
               communicable: lead,
               company_id: company.id,
               to_address: lead.email,
               sent_at: sent_at)

        expect(described_class.already_logged?(
          message_id: nil, communicable: lead, to_address: lead.email, sent_at: sent_at
        )).to be false
      end

      it 'does not match a different lead' do
        other = create(:lead, company: company, email: 'someone-else@example.com')
        create(:communication, :sent,
               communicable: other,
               company_id: company.id,
               to_address: other.email,
               sent_at: sent_at)

        expect(described_class.already_logged?(
          message_id: nil, communicable: lead, to_address: lead.email, sent_at: sent_at
        )).to be false
      end

      it 'returns false when there is nothing to compare against' do
        expect(described_class.already_logged?(message_id: nil)).to be false
      end
    end
  end
end

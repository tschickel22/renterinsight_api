# frozen_string_literal: true

require 'rails_helper'

# Replying to a customer meant opening the compose tab and retyping the
# recipient and subject: the message dialog offered Close and Delete and nothing
# else. Worse than the retyping, the answer filed as its own unrelated event, so
# an exchange read as a pile of notes in reverse date order.
RSpec.describe 'Api::Platform::Communications replying', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { 'Authorization' => "Bearer #{token}" } }
  let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead) do
    Lead.create!(company: company, source: source, first_name: 'Dana', last_name: 'Reyes',
                 email: 'dana@example.com')
  end

  # What a customer's reply looks like once the inbound webhook has filed it.
  let!(:inbound) do
    Communication.create!(
      company_id: company.id, communicable: lead, channel: 'email', direction: 'inbound',
      subject: 'Re: Your quote', body: 'Still interested, what are the next steps?',
      from_address: 'dana.work@example.com', to_address: 'sales@dealer.com',
      status: 'delivered', sent_at: 1.hour.ago
    )
  end

  describe 'GET history' do
    it 'says which way each message went' do
      get "/api/platform/communications/Lead/#{lead.id}/history", headers: headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).first['direction']).to eq('inbound')
    end

    # A customer who writes from their work account should get the answer where
    # they wrote from, not at whatever address is on the record.
    it 'says who it was between, so a reply can go back to the right address' do
      get "/api/platform/communications/Lead/#{lead.id}/history", headers: headers

      row = JSON.parse(response.body).first
      expect(row['fromAddress']).to eq('dana.work@example.com')
      expect(row['toAddress']).to eq('sales@dealer.com')
    end
  end

  describe 'threading' do
    # Email has to look configured or the controller returns before it records
    # anything, and the send itself reaches a real provider, which is not what
    # any of this is about. Both stood in for so the subject is the threading.
    before do
      PlatformSetting.communications = {
        email: { provider: 'smtp', fromEmail: 'sales@dealer.com',
                 smtpHost: 'smtp.example.com', smtpPort: 587, isEnabled: true }
      }
      allow_any_instance_of(Api::Platform::CommunicationsController)
        .to receive(:send_email_via_action_mailer).and_return({ success: true, provider: 'smtp' })
      allow_any_instance_of(Api::Platform::CommunicationsController)
        .to receive(:configure_action_mailer_smtp).and_return(true)
    end

    def reply_with(in_reply_to_id)
      post '/api/platform/communications/email',
           params: { entity_type: 'Lead', entity_id: lead.id, to: 'dana.work@example.com',
                     subject: 'Re: Your quote', body: 'Here is what happens next.',
                     in_reply_to_id: in_reply_to_id },
           headers: headers
    end

    # Grouping is not this endpoint's job: Communication has
    # before_create :assign_to_thread, which puts every message for an entity
    # and channel in one thread already. What that cannot say is which message
    # a reply answers, and a conversation with several open questions needs it.
    it 'records which message was answered' do
      reply_with(inbound.id)

      outbound = Communication.where(company_id: company.id).where(direction: 'outbound').order(:created_at).last
      expect(outbound.metadata['in_reply_to_id']).to eq(inbound.id)
    end

    it 'leaves an ordinary send with no reference' do
      post '/api/platform/communications/email',
           params: { entity_type: 'Lead', entity_id: lead.id, to: 'dana@example.com',
                     subject: 'Checking in', body: 'Just following up.' },
           headers: headers

      outbound = Communication.where(company_id: company.id).where(direction: 'outbound').order(:created_at).last
      expect(outbound.metadata['in_reply_to_id']).to be_nil
    end

    it 'still puts the reply in the same thread as the message it answers' do
      reply_with(inbound.id)

      outbound = Communication.where(company_id: company.id).where(direction: 'outbound').order(:created_at).last
      expect(outbound.communication_thread_id).to eq(inbound.reload.communication_thread_id)
      expect(outbound.communication_thread_id).to be_present
    end

    # An id in a request is not evidence of anything. Pointing a reply at
    # another customer's message would file the wrong reference against this one.
    it 'refuses a reference to a message belonging to someone else' do
      other_lead = Lead.create!(company: company, source: source, first_name: 'Sam',
                                last_name: 'Other', email: 'sam@example.com')
      theirs = Communication.create!(
        company_id: company.id, communicable: other_lead, channel: 'email', direction: 'inbound',
        subject: 'Different conversation', body: 'Hello', status: 'delivered',
        from_address: 'sam@example.com', to_address: 'sales@dealer.com'
      )

      reply_with(theirs.id)

      outbound = Communication.where(company_id: company.id).where(direction: 'outbound').order(:created_at).last
      expect(outbound.metadata['in_reply_to_id']).to be_nil
    end

    # A reply arrived carrying only the new sentence, so the customer had to
    # remember what they had asked and their own mail client had nothing to
    # thread it against.
    describe 'what the customer receives' do
      it 'quotes the message being answered' do
        reply_with(inbound.id)

        outbound = Communication.where(company_id: company.id).where(direction: 'outbound').order(:created_at).last
        expect(outbound.body).to include('Here is what happens next.')
        expect(outbound.body).to include('Still interested, what are the next steps?')
        expect(outbound.body).to include('dana.work@example.com wrote:')
      end

      it 'quotes nothing on an ordinary send' do
        post '/api/platform/communications/email',
             params: { entity_type: 'Lead', entity_id: lead.id, to: 'dana@example.com',
                       subject: 'Checking in', body: 'Just following up.' },
             headers: headers

        outbound = Communication.where(company_id: company.id).where(direction: 'outbound').order(:created_at).last
        expect(outbound.body).not_to include('wrote:')
      end

      # Quoting a previous outbound verbatim would carry its tracking pixel into
      # every later message in the thread, so opening today's reply would
      # register an open against a mail sent last week and the counts on old
      # messages would climb on their own.
      it 'strips the tracking pixel out of what it quotes' do
        sent = Communication.create!(
          company_id: company.id, communicable: lead, channel: 'email', direction: 'outbound',
          subject: 'Your quote', status: 'sent', from_address: 'sales@dealer.com',
          to_address: 'dana@example.com',
          body: '<p>Here is your quote.</p><img src="https://x.test/webhooks/email/4242/pixel.gif" width="1" />'
        )

        reply_with(sent.id)

        outbound = Communication.where(company_id: company.id).where(direction: 'outbound').order(:created_at).last
        expect(outbound.body).to include('Here is your quote.')
        expect(outbound.body).not_to include('/webhooks/email/4242/pixel.gif')
      end

      # Its own pixel still has to be there, and outside the quoted block.
      it 'keeps a pixel for the message being sent' do
        reply_with(inbound.id)

        outbound = Communication.where(company_id: company.id).where(direction: 'outbound').order(:created_at).last
        expect(outbound.body).to include("/webhooks/email/#{outbound.id}/pixel.gif")
      end
    end
  end
end

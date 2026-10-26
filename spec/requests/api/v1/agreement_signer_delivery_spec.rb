# frozen_string_literal: true

require 'rails_helper'

# A signer whose invite does not go out. A blocked email address used to stop the
# text and the portal push to that same signer too, and the failure lived only in
# the worker log, so the agreement read as sent. Each channel now stands alone,
# the failure shows on the signer, and an unsigned signer's address can be fixed
# after sending, which re-sends their invite on a fresh link.
RSpec.describe 'Agreement signer delivery', type: :request do
  let(:company) { Company.create!(name: "Signer Co #{SecureRandom.hex(3)}") }
  let(:user) { User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:agreement) do
    company.agreements.create!(title: 'Purchase Agreement', status: 'partially_signed', delivery_method: 'both', prepared_by: user, sent_at: 1.day.ago)
  end
  let!(:buyer) { agreement.agreement_signers.create!(name: 'Matt Buyer', email: 'matt@example.com', phone: '3035550100', role: 'signer', signing_order: 1, status: 'signed', signed_at: 1.hour.ago) }
  let!(:dealer) { agreement.agreement_signers.create!(name: 'Tom Dealer', email: 'dead@example.com', phone: '3035550199', role: 'counter_signer', signing_order: 2) }

  def body = JSON.parse(response.body)

  before do
    allow(PortalPushService).to receive(:document_to_sign)
    allow(PortalPushService).to receive(:document_signature_reminder)
    allow(CommunicationService).to receive(:send_sms).and_return({ success: true })
    allow(CommunicationService).to receive(:send_email) do |args|
      raise CommunicationService::SuppressedRecipientError, "#{args[:to]} cannot be emailed: a previous send hard bounced or was reported as spam" if args[:to] == 'dead@example.com'
      { success: true }
    end
  end

  it 'still texts the signer when their email is blocked, and says so on the signer' do
    SendAgreementJob.perform_now(agreement.id, dealer.id)

    expect(CommunicationService).to have_received(:send_sms).with(hash_including(to: '3035550199'))
    expect(PortalPushService).to have_received(:document_to_sign).with(agreement: agreement, signer: dealer)
    expect(dealer.reload.delivery_error).to eq('Email: dead@example.com cannot be emailed: a previous send hard bounced or was reported as spam')
    expect(agreement.agreement_audit_logs.where(action: 'delivery_failed', agreement_signer: dealer)).to exist

    get "/api/v1/agreements/#{agreement.id}", headers: headers
    row = body['signers'].find { |s| s['id'] == dealer.id }
    expect(row['delivery_error']).to include('hard bounced')
  end

  it 'reminds just the countersigner, and refuses a signer who already signed' do
    post "/api/v1/agreements/#{agreement.id}/remind_signer", headers: headers, params: { signer_id: buyer.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)

    perform_enqueued_jobs do
      post "/api/v1/agreements/#{agreement.id}/remind_signer", headers: headers, params: { signer_id: dealer.id }.to_json
    end
    expect(response).to have_http_status(:ok)
    expect(CommunicationService).to have_received(:send_sms).with(hash_including(to: '3035550199', metadata: hash_including(type: 'signing_reminder_sms')))
    expect(agreement.agreement_reminders.last).to have_attributes(agreement_signer_id: dealer.id, status: 'sent')
  end

  it 'corrects an unsigned signer after sending, retires the old link and re-sends the invite' do
    dealer.update_columns(delivery_error: 'Email: blocked', delivery_error_at: Time.current)
    old_token = dealer.access_token

    perform_enqueued_jobs do
      patch "/api/v1/agreements/#{agreement.id}/signers/#{dealer.id}", headers: headers,
            params: { signer: { email: 'tom@example.com', role: 'signer', signing_order: 9 } }.to_json
    end

    expect(response).to have_http_status(:ok)
    dealer.reload
    expect(dealer).to have_attributes(email: 'tom@example.com', role: 'counter_signer', signing_order: 2, delivery_error: nil)
    expect(dealer.access_token).not_to eq(old_token)
    expect(CommunicationService).to have_received(:send_email).with(hash_including(to: 'tom@example.com', metadata: hash_including(type: 'signing_invitation')))
    expect(CommunicationService).not_to have_received(:send_email).with(hash_including(to: 'matt@example.com'))
    log = agreement.agreement_audit_logs.find_by(action: 'signer_updated')
    expect(log.metadata['changes']['email']).to eq('from' => 'dead@example.com', 'to' => 'tom@example.com')
  end

  it 'will not change a signer who already signed' do
    patch "/api/v1/agreements/#{agreement.id}/signers/#{buyer.id}", headers: headers,
          params: { signer: { email: 'other@example.com' } }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(buyer.reload.email).to eq('matt@example.com')
  end
end

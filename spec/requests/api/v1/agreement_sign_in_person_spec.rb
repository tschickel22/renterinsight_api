# frozen_string_literal: true

require 'rails_helper'

# A buyer standing at the desk signs on the dealer's own screen. Nothing is emailed or
# texted, a walk-in with no email address can still sign electronically, and the
# signature is marked in person only while the short window Sign Now opened is live.
RSpec.describe 'Agreement sign in person', type: :request do
  let(:company) { Company.create!(name: "Desk Co #{SecureRandom.hex(3)}") }
  let(:user) { User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:agreement) { company.agreements.create!(title: 'Purchase Agreement', status: 'draft', delivery_method: 'email', prepared_by: user) }
  # A buyer on file as a contact may have no email at all.
  let(:contact) { company.contacts.create!(first_name: 'Walk', last_name: 'In') }
  let!(:buyer) { agreement.agreement_signers.create!(name: 'Walk In', email: '', role: 'signer', signing_order: 1, signable: contact) }

  def body = JSON.parse(response.body)

  before do
    allow(CommunicationService).to receive(:send_email).and_return({ success: true })
    allow(CommunicationService).to receive(:send_sms).and_return({ success: true })
  end

  it 'opens a draft for a signer with no email, sends nothing, and returns their token' do
    perform_enqueued_jobs do
      post "/api/v1/agreements/#{agreement.id}/sign_in_person", headers: headers, params: { signer_id: buyer.id }.to_json
    end

    expect(response).to have_http_status(:ok)
    expect(body['token']).to eq(buyer.reload.access_token)
    expect(agreement.reload.status).to eq('sent')
    expect(buyer.hosted_by_user_id).to eq(user.id)
    expect(buyer.in_person_until).to be > 25.minutes.from_now
    expect(agreement.agreement_audit_logs.pluck(:action)).to include('in_person_started', 'in_person_handoff')
    expect(CommunicationService).not_to have_received(:send_email)
    expect(CommunicationService).not_to have_received(:send_sms)
  end

  it 'marks a signature inside the window as in person and closes the window' do
    buyer.start_in_person!(user)
    agreement.update!(status: 'sent')

    buyer.sign!(signature_method: 'typed', typed_signature: 'Walk In', ip_address: '1.2.3.4')

    buyer.reload
    expect(buyer.signed_in_person).to be(true)
    expect(buyer.in_person_until).to be_nil
    log = agreement.agreement_audit_logs.where(agreement_signer: buyer).order(:created_at).last
    expect(log.metadata).to include('in_person' => true, 'hosted_by' => user.name)
  end

  it 'does not mark a signature made after the window ran out' do
    buyer.start_in_person!(user)
    buyer.update_columns(in_person_until: 1.minute.ago)
    agreement.update!(status: 'sent')

    buyer.sign!(signature_method: 'typed', typed_signature: 'Walk In')

    expect(buyer.reload.signed_in_person).to be(false)
  end

  it 'refuses a signer who already signed' do
    buyer.update!(status: 'signed', signed_at: Time.current)
    post "/api/v1/agreements/#{agreement.id}/sign_in_person", headers: headers, params: { signer_id: buyer.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'will not hand over a voided agreement' do
    agreement.update!(status: 'voided')
    post "/api/v1/agreements/#{agreement.id}/sign_in_person", headers: headers, params: { signer_id: buyer.id }.to_json
    expect(response).to have_http_status(:unprocessable_entity)
    expect(buyer.reload.in_person_until).to be_nil
  end

  it 'cannot reach another company\'s signer' do
    other = Company.create!(name: "Other #{SecureRandom.hex(3)}").agreements.create!(title: 'X', status: 'draft', delivery_method: 'email')
    stranger = other.agreement_signers.create!(name: 'Stranger', email: 's@example.com', role: 'signer', signing_order: 1)
    post "/api/v1/agreements/#{agreement.id}/sign_in_person", headers: headers, params: { signer_id: stranger.id }.to_json
    expect(response).to have_http_status(:not_found)
  end
end

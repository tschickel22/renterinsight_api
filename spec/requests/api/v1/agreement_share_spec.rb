# frozen_string_literal: true

require 'rails_helper'

# View opens the signed PDF in the browser; Share sends it as a 30-day link by
# email and/or text through CommunicationService; the link opens the PDF.
RSpec.describe 'Agreement view and share', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Tom', last_name: 'Schickel',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:account) { company.accounts.create!(name: 'Alexander Franco') }
  let!(:contact) do
    company.contacts.create!(first_name: 'Alex', last_name: 'Franco', email: 'alex@example.com', phone: '+13525550100',
                             account_id: account.id)
  end
  let(:sealed_ref) { 'private://dealertide-private-test/agreements/1/signed/franco.pdf' }
  let!(:agreement) do
    a = company.agreements.create!(title: 'Franco contract', content_type: 'upload', account_id: account.id)
    a.update_columns(status: 'completed', completed_at: 1.day.ago, sealed_document_url: sealed_ref)
    a
  end

  before do
    allow(PrivateFiles).to receive(:url) { |_v, **opts| "https://s3.example.com/franco.pdf?d=#{opts[:disposition] || 'inline'}" }
  end

  it 'gives an inline link for View and an attachment link by default' do
    get "/api/v1/agreements/#{agreement.id}/download", params: { disposition: 'inline' }, headers: headers
    expect(JSON.parse(response.body)['url']).to end_with('d=inline')

    get "/api/v1/agreements/#{agreement.id}/download", headers: headers
    expect(JSON.parse(response.body)['url']).to end_with('d=attachment')
  end

  it 'suggests the account contacts with a share link' do
    get "/api/v1/agreements/#{agreement.id}/share_options", headers: headers

    body = JSON.parse(response.body)
    expect(body['recipients']).to include(include('name' => 'Alex Franco', 'email' => 'alex@example.com',
                                                  'phone' => '352-555-0100', 'contact_id' => contact.id))
    expect(body['link']).to include('/agreement_files/')
  end

  it 'sends by email and text through CommunicationService on the contact' do
    expect(CommunicationService).to receive(:send_email)
      .with(hash_including(communicable: contact, to: 'alex@example.com', category: 'agreements'))
      .and_return(success: true)
    expect(CommunicationService).to receive(:send_sms)
      .with(hash_including(communicable: contact, to: '+13525550100', body: a_string_including('/agreement_files/')))
      .and_return(success: true)

    post "/api/v1/agreements/#{agreement.id}/share",
         params: { channels: %w[email sms], to_email: 'alex@example.com', to_phone: '+13525550100',
                   contact_id: contact.id },
         headers: headers

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['sent'].map { |s| s['channel'] }).to eq(%w[email sms])
    expect(agreement.agreement_audit_logs.where(action: 'shared').count).to eq(1)
  end

  it 'reports an opt-out instead of sending' do
    allow(CommunicationService).to receive(:send_sms).and_raise(CommunicationService::OptOutError)

    post "/api/v1/agreements/#{agreement.id}/share", params: { channels: %w[sms], to_phone: '+13525550100' },
                                                      headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
    expect(JSON.parse(response.body)['errors'].first).to include('opted out')
  end

  it 'refuses to share an agreement that is not completed' do
    agreement.update_columns(status: 'sent')

    post "/api/v1/agreements/#{agreement.id}/share", params: { channels: %w[email], to_email: 'a@example.com' },
                                                      headers: headers

    expect(response).to have_http_status(:unprocessable_entity)
  end

  describe 'the shared link' do
    it 'opens the signed PDF' do
      token = agreement.signed_id(purpose: Agreements::Share::PURPOSE, expires_in: 30.days)
      get "/agreement_files/#{token}"

      expect(response).to redirect_to('https://s3.example.com/franco.pdf?d=inline')
    end

    it 'stops working once expired' do
      token = agreement.signed_id(purpose: Agreements::Share::PURPOSE, expires_in: 30.days)
      travel 31.days do
        get "/agreement_files/#{token}"
      end

      expect(response).to have_http_status(:not_found)
    end

    it 'does not accept a token made for another purpose' do
      get "/agreement_files/#{agreement.signed_id(purpose: :something_else)}"

      expect(response).to have_http_status(:not_found)
    end
  end
end

# frozen_string_literal: true

require 'rails_helper'

# Credit applications (sensitive templates): signer answers are encrypted and kept
# only until the signed PDF exists, no signer sees another's answers, a signed one
# is not handed out through signing links, and sharing sends a password-locked copy
# for a window that a company admin can renew.
RSpec.describe 'Sensitive agreements', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'Ann', last_name: 'Admin',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:headers_for) { ->(u) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: u.id, company_id: company.id)}" } } }
  let(:sealed_ref) { "private://dealertide-private-test/agreements/#{company.id}/signed/app.pdf" }
  let(:agreement) do
    company.agreements.create!(title: 'App for Financing', content_type: 'upload', sensitive: true, status: 'sent',
                               merge_field_values: { 'contact.first_name' => 'Jane' })
  end
  let!(:applicant) { agreement.agreement_signers.create!(name: 'Jane Doe', email: 'jane@example.com', role: 'signer', signing_order: 0) }
  let!(:co_applicant) { agreement.agreement_signers.create!(name: 'John Doe', email: 'john@example.com', role: 'signer', signing_order: 1) }

  before do
    allow(SealAgreementJob).to receive(:perform_later)
    allow(SealAgreementJob).to receive(:perform_now)
    allow(PrivateFiles).to receive(:url) { |v, **_| "https://s3.example.com/#{v.to_s.split('/').last}" }
  end

  def sign_as(signer, values)
    post "/sign/#{signer.access_token}/sign", params: { typed_signature: signer.name, signature_method: 'type',
                                                        field_values: values }
  end

  it 'keeps answers encrypted, out of merge values, and away from the other signer' do
    sign_as(applicant, { 'credit_app.a_ssn' => '123-45-6789' })
    expect(response).to have_http_status(:ok)

    agreement.reload
    expect(agreement.sensitive_answers).to eq('credit_app.a_ssn' => '123-45-6789')
    expect(agreement.merge_field_values).not_to have_key('credit_app.a_ssn')
    raw = Agreement.connection.select_value("SELECT sensitive_values FROM agreements WHERE id = #{agreement.id}")
    expect(raw).not_to include('123-45-6789')

    get "/sign/#{co_applicant.access_token}"
    expect(response.body).not_to include('123-45-6789')
    expect(JSON.parse(response.body).dig('agreement', 'merge_field_values')).to include('contact.first_name' => 'Jane')
  end

  it 'stamps the answers when sealing, then clears them' do
    agreement.add_sensitive_answers!('credit_app.a_ssn' => '123-45-6789')
    service = AgreementPdfService.new(agreement)

    expect(service.send(:build_values_map)).to include('credit_app.a_ssn' => '123-45-6789')
    expect(service.send(:sealed_attributes, sealed_ref)).to eq(sealed_document_url: sealed_ref, sensitive_values: nil)
  end

  context 'once signed' do
    before { agreement.update_columns(status: 'completed', completed_at: 1.day.ago, sealed_document_url: sealed_ref) }

    it 'is not handed out again through a signing link' do
      get "/sign/#{co_applicant.access_token}"
      expect(response).to have_http_status(:gone)
      get "/sign/#{co_applicant.access_token}/download"
      expect(response).to have_http_status(:gone)
    end

    it 'shares only as a locked copy, with the password returned once' do
      # As S3 hands it back: binary bytes labelled UTF-8 (what broke blank? on staging).
      allow(PrivateFiles).to receive(:read).and_return("%PDF-1.4\n%\xE2\xE3\xCF\xD3".dup.force_encoding('UTF-8'))
      allow(Agreements::LockedCopy).to receive(:lock).and_return('%PDF-locked')
      allow(PrivateFiles).to receive(:put) { |_body, key:, **| "private://dealertide-private-test/#{key}" }
      allow(PrivateFiles).to receive(:owned_by?).and_return(true)

      get "/api/v1/agreements/#{agreement.id}/share_options", headers: headers_for.call(admin)
      body = JSON.parse(response.body)
      expect(body).to include('sensitive' => true, 'link' => nil)

      post "/api/v1/agreements/#{agreement.id}/locked_copy", headers: headers_for.call(admin)
      body = JSON.parse(response.body)
      expect(body['password']).to match(/\A[A-Z2-9]{4}-[A-Z2-9]{4}-[A-Z2-9]{4}\z/)
      expect(body['download_url']).to match(%r{/#{agreement.id}-\h{16}\.pdf\z})

      get URI(body['link']).path
      expect(response).to have_http_status(:redirect)
      expect(response.location).to match(%r{/#{agreement.id}-\h{16}\.pdf\z})
    end

    it 'sends the password in its own text and keeps it out of the saved message' do
      comm = Communication.new
      expect(CommunicationService).to receive(:send_sms)
        .with(hash_including(to: '303-555-0100', body: include('ABCD-EFGH-JKMN')))
        .and_return(success: true, communication: comm)
      expect(comm).to receive(:update_columns).with(body: include('[password removed after sending]'))

      post "/api/v1/agreements/#{agreement.id}/send_password",
           params: { password: 'ABCD-EFGH-JKMN', channel: 'sms', to: '303-555-0100' }, headers: headers_for.call(admin)
      expect(response).to have_http_status(:ok)

      post "/api/v1/agreements/#{agreement.id}/send_password",
           params: { password: 'anything at all', channel: 'sms', to: '303-555-0100' }, headers: headers_for.call(admin)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'never opens through an old plain share link' do
      token = agreement.signed_id(purpose: Agreements::Share::PURPOSE, expires_in: 30.days)
      get "/agreement_files/#{token}"
      expect(response).to have_http_status(:not_found)
    end

    it 'closes sharing after the window and lets a company admin open it again' do
      agreement.update_columns(completed_at: 31.days.ago)
      rep = User.create!(email: "r-#{SecureRandom.hex(4)}@example.com", first_name: 'Rep', last_name: 'One',
                         password: 'Pass1234!', company_id: company.id, role: 'sales_rep')
      allow_any_instance_of(Api::V1::AgreementsController).to receive(:authorize_action!).and_return(true)

      get "/api/v1/agreements/#{agreement.id}/share_options", headers: headers_for.call(admin)
      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)).to include('share_closed' => true, 'can_renew' => true)

      post "/api/v1/agreements/#{agreement.id}/renew_sharing", headers: headers_for.call(rep)
      expect(response).to have_http_status(:forbidden)

      post "/api/v1/agreements/#{agreement.id}/renew_sharing", headers: headers_for.call(admin)
      expect(response).to have_http_status(:ok)
      expect(agreement.reload.share_window_open?).to be(true)
    end
  end

  it 'becomes sensitive when the template is picked after the draft was auto-saved' do
    template = company.agreement_templates.create!(name: 'App for Financing', template_type: 'upload', status: 'active',
                                                   sensitive: true)
    post '/api/v1/agreements', params: { agreement: { title: 'Test Loan App' } }, headers: headers_for.call(admin)
    draft = Agreement.find(JSON.parse(response.body)['id'] || JSON.parse(response.body).dig('agreement', 'id'))
    expect(draft.sensitive).to be(false)

    patch "/api/v1/agreements/#{draft.id}", params: { agreement: { title: 'Test Loan App', agreement_template_id: template.id } },
                                             headers: headers_for.call(admin)
    expect(response).to have_http_status(:ok)
    expect(draft.reload).to have_attributes(agreement_template_id: template.id, sensitive: true)
  end

  it 'lets a rep mark an agreement sensitive but not unmark one from a sensitive template' do
    plain = company.agreement_templates.create!(name: 'Notice', template_type: 'upload', status: 'active')
    secret = company.agreement_templates.create!(name: 'App for Financing', template_type: 'upload', status: 'active',
                                                 sensitive: true)
    headers = headers_for.call(admin)

    post '/api/v1/agreements', params: { agreement: { title: 'Upload', agreement_template_id: plain.id, sensitive: true } }, headers: headers
    expect(Agreement.order(:id).last.sensitive).to be(true)

    post '/api/v1/agreements', params: { agreement: { title: 'App', agreement_template_id: secret.id, sensitive: false } }, headers: headers
    app = Agreement.order(:id).last
    expect(app.sensitive).to be(true)
    patch "/api/v1/agreements/#{app.id}", params: { agreement: { sensitive: false } }, headers: headers
    expect(app.reload.sensitive).to be(true)

    patch "/api/v1/agreement_templates/#{plain.id}", params: { agreement_template: { sensitive: true } }, headers: headers
    expect(JSON.parse(response.body)['sensitive']).to be(true)
  end

  it 'locks a PDF with a password (qpdf)', if: system('which qpdf > /dev/null 2>&1') do
    pdf = Prawn::Document.new.tap { |d| d.text 'hello' }.render
    locked = Agreements::LockedCopy.lock(pdf, 'ABCD-EFGH-JKMN')
    expect(locked).to include('/Encrypt')
  end
end

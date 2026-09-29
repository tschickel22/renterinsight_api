# frozen_string_literal: true

require 'rails_helper'
require Rails.root.join('spec/support/private_files_stub')

# Confidential files live in a private bucket and are handed out as expiring
# links. These cover the holes closed alongside the move.
RSpec.describe 'Private file access', type: :request do
  let!(:s3) { stub_private_files }
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:other_company) { Company.create!(name: "Other-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:agreement) { company.agreements.create!(title: 'Purchase agreement', status: 'draft') }

  describe 'POST /api/v1/agreement_documents/merge' do
    it 'refuses URLs that are not this company’s stored files instead of fetching them' do
      post '/api/v1/agreement_documents/merge', headers: headers, params: {
        agreement_id: agreement.id,
        pdf_urls: ['http://169.254.169.254/latest/meta-data/', "s3://dt-private-test/agreements/#{company.id}/documents/a.pdf"]
      }
      expect(response).to have_http_status(:forbidden)

      post '/api/v1/agreement_documents/merge', headers: headers, params: {
        agreement_id: agreement.id,
        pdf_urls: ["s3://dt-private-test/agreements/#{other_company.id}/documents/a.pdf",
                   "s3://dt-private-test/agreements/#{company.id}/documents/b.pdf"]
      }
      expect(response).to have_http_status(:forbidden)
      expect(s3.api_requests.map { |r| r[:operation_name] }).not_to include(:get_object)
    end
  end

  describe 'agreement JSON' do
    it 'returns expiring links, never the stored reference' do
      agreement.update!(document_url: "https://legacy-public-test.s3.us-west-2.amazonaws.com/agreements/#{company.id}/documents/a.pdf")
      expect(agreement.reload.document_url).to eq("s3://legacy-public-test/agreements/#{company.id}/documents/a.pdf")

      get "/api/v1/agreements/#{agreement.id}", headers: headers
      body = JSON.parse(response.body)
      doc_url = body['document_url'] || body.dig('agreement', 'document_url') || body.dig('data', 'document_url')
      expect(doc_url).to include('X-Amz-Signature=')
      expect(response.body).not_to include('s3://')
    end
  end

  describe 'DELETE /api/v1/bills/:id/delete_attachment' do
    it 'deletes only a file attached to that bill' do
      bill = company.bills.create!(bill_date: Date.current, status: 'draft')
      bill.update_columns(attachments: [{ 'url' => "s3://dt-private-test/bills/#{company.id}/#{bill.id}/a.pdf",
                                          's3_key' => "bills/#{company.id}/#{bill.id}/a.pdf" }])

      delete "/api/v1/bills/#{bill.id}/delete_attachment", headers: headers,
                                                           params: { s3_key: "agreements/#{other_company.id}/sealed/x.pdf" }
      expect(response).to have_http_status(:not_found)
      expect(s3.api_requests.map { |r| r[:operation_name] }).not_to include(:delete_object)

      delete "/api/v1/bills/#{bill.id}/delete_attachment", headers: headers,
                                                           params: { s3_key: "bills/#{company.id}/#{bill.id}/a.pdf" }
      expect(response).to have_http_status(:no_content)
      expect(s3.api_requests.last[:params]).to include(bucket: 'dt-private-test', key: "bills/#{company.id}/#{bill.id}/a.pdf")
      expect(bill.reload.attachments).to eq([])
    end
  end

  describe 'PUT /api/v1/users/me/signature' do
    it 'refuses another company’s file as a saved signature' do
      put '/api/v1/users/me/signature', headers: headers,
                                        params: { signature_url: "s3://dt-private-test/agreements/#{other_company.id}/sealed/x.pdf" }
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe 'POST /sign/:token/sign' do
    it 'refuses a URL where a drawn or typed signature belongs' do
      signer = agreement.agreement_signers.create!(name: 'Buyer', email: 'buyer@example.com', role: 'signer')
      post "/sign/#{signer.access_token}/sign", params: { signature_data: 'https://example.com/sig.png' }
      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)['error']).to eq('Signature must be drawn or typed')
    end
  end

  describe 'GET /pf/:token' do
    it 'redirects a signed link to a short-lived presigned URL and rejects a forged one' do
      link = PrivateFiles.durable_url("s3://dt-private-test/custom-fields/#{company.id}/leads/1/a.pdf")
      get URI(link).path
      expect(response).to have_http_status(:found)
      expect(response.location).to include('dt-private-test', 'X-Amz-Expires=300')

      get "#{URI(link).path}tampered"
      expect(response).to have_http_status(:not_found)
    end
  end
end

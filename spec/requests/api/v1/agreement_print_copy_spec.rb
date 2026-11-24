# frozen_string_literal: true

require 'rails_helper'
require 'pdf/reader'

# Printing used to send pictures of the pages made at screen resolution, and a
# dealer's contract came out blurry on paper (Coastal Breeze, 2026-11-24). The
# print copy is the real PDF with the values drawn in as text.
RSpec.describe 'Agreement print copy', type: :request do
  let(:company) { Company.create!(name: "Print Co #{SecureRandom.hex(3)}") }
  let(:user) { User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Cedric', last_name: 'Calloway', password: 'Pass1234!', company_id: company.id, role: 'company_admin') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }
  let(:blank_form) do
    pdf = Prawn::Document.new(page_size: 'LETTER')
    pdf.text 'PURCHASE AGREEMENT'
    "data:application/pdf;base64,#{Base64.strict_encode64(pdf.render)}"
  end
  let(:agreement) do
    company.agreements.create!(
      title: 'Purchase Agreement', status: 'draft', prepared_by: user, content_type: 'pdf_upload',
      document_url: blank_form,
      merge_field_values: { 'custom.buyer_names' => 'Keianna Walker' },
      merge_field_placements: [
        { 'id' => 'b1', 'page' => 0, 'x' => 10, 'y' => 20, 'width' => 50, 'height' => 3,
          'fieldKey' => 'custom.buyer_names', 'fieldType' => 'text', 'isCustomField' => true, 'isSignerField' => false },
        { 'id' => 's1', 'page' => 0, 'x' => 10, 'y' => 80, 'width' => 30, 'height' => 4,
          'fieldKey' => 'signer.signature', 'fieldType' => 'signature', 'signerIndex' => 0, 'isSignerField' => true }
      ]
    )
  end
  before { agreement.agreement_signers.create!(name: 'Keianna Walker', email: 'k@example.com', role: 'signer', signing_order: 1) }

  it 'returns the PDF with the values drawn in as real text and the unsigned line left blank' do
    get "/api/v1/agreements/#{agreement.id}/print_copy", headers: headers

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('application/pdf')
    text = PDF::Reader.new(StringIO.new(response.body)).pages.map(&:text).join("\n")
    expect(text).to include('PURCHASE AGREEMENT')
    expect(text).to include('Keianna Walker')
    expect(agreement.agreement_audit_logs.where(action: 'downloaded').last.metadata).to include('via' => 'print')
  end

  it 'says so when there is no PDF' do
    agreement.update_columns(document_url: nil)
    get "/api/v1/agreements/#{agreement.id}/print_copy", headers: headers
    expect(response).to have_http_status(:not_found)
  end
end

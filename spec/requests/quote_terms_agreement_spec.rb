# frozen_string_literal: true

require 'rails_helper'

# A quote with terms and conditions used to be accepted from the buyer portal
# and the emailed link without the buyer ever seeing the terms. Now the buyer
# has to tick that they agree, and the quote keeps when and to which wording.
RSpec.describe 'Quote terms agreement', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:account) { Account.create!(company: company, name: 'Buyer Account', status: 'active') }
  let(:contact) do
    Contact.create!(company: company, account: account, first_name: 'Hannah', last_name: 'Whitfield',
                    email: "h-#{SecureRandom.hex(4)}@example.com")
  end
  let(:terms) { "50% deposit due at signing.\nDeposit is non-refundable once the home is ordered." }
  let(:quote) do
    Quote.create!(company: company, account: account, contact: contact, status: 'sent',
                  subtotal: 100, total: 100, items: [], terms: terms)
  end

  describe 'the emailed link' do
    it 'shows the buyer the terms' do
      get "/q/#{quote.public_token}"

      expect(response.parsed_body.dig('quote', 'terms')).to eq(terms)
    end

    it 'will not accept without agreeing to the terms' do
      post "/q/#{quote.public_token}/accept"

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include('terms_required' => true)
      expect(quote.reload.status).to eq('sent')
    end

    it 'records when the buyer agreed and the exact wording' do
      post "/q/#{quote.public_token}/accept", params: { agreed_to_terms: true }, as: :json

      expect(response).to have_http_status(:ok)
      quote.reload
      expect(quote.status).to eq('accepted')
      expect(quote.terms_agreed_at).to be_present
      expect(quote.agreed_terms).to eq(terms)
      expect(response.parsed_body.dig('quote', 'terms_agreed_at')).to be_present
    end

    it 'keeps what they agreed to when the dealer edits the terms later' do
      post "/q/#{quote.public_token}/accept", params: { agreed_to_terms: true }, as: :json
      quote.update!(terms: 'Something else entirely.')

      expect(quote.reload.agreed_terms).to eq(terms)
    end

    it 'says so on the printed quote' do
      quote.accept!(ip: '203.0.113.9', via: 'public_link', by: 'Hannah Whitfield', terms_agreed: true)

      expect(quote.acceptance_summary).to end_with('from IP 203.0.113.9, agreeing to the terms and conditions')
    end

    it 'asks nothing extra of a quote with no terms' do
      quote.update!(terms: '  ')

      post "/q/#{quote.public_token}/accept"

      expect(quote.reload.status).to eq('accepted')
      expect(quote.terms_agreed_at).to be_nil
    end
  end

  describe 'the buyer portal' do
    let(:portal_access) do
      BuyerPortalAccess.create!(buyer: contact, company: company, email: contact.email,
                                password: 'Password123!', password_confirmation: 'Password123!',
                                portal_enabled: true)
    end
    let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode({ buyer_portal_access_id: portal_access.id }, 1.hour.from_now)}" } }

    it 'shows the buyer the terms' do
      get "/api/portal/quotes/#{quote.id}", headers: headers

      expect(response.parsed_body.dig('quote', 'terms')).to eq(terms)
    end

    it 'will not accept without agreeing to the terms' do
      patch "/api/portal/quotes/#{quote.id}/accept", headers: headers

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body).to include('terms_required' => true)
      expect(quote.reload.status).to eq('sent')
    end

    it 'records the agreement when the buyer ticks the box' do
      patch "/api/portal/quotes/#{quote.id}/accept", params: { agreed_to_terms: true }, headers: headers, as: :json

      expect(response).to have_http_status(:ok)
      expect(quote.reload).to have_attributes(status: 'accepted', accepted_via: 'portal', agreed_terms: terms)
    end
  end

  # The dealer marking a quote accepted is not the buyer agreeing to anything.
  it 'does not record an agreement when the dealer marks it accepted' do
    quote.accept!(ip: '198.51.100.4', via: 'dealer', by: 'Alex Morgan')

    expect(quote.reload.terms_agreed_at).to be_nil
  end
end

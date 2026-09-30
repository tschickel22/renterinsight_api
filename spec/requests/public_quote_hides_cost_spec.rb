# frozen_string_literal: true

require 'rails_helper'

# Quote items built from templates and products carry the dealer's cost. The
# public quote link returned items as stored, so a customer could read cost
# out of the page data.
RSpec.describe 'Public quote page', type: :request do
  let(:company) { create(:company) }
  let(:quote) do
    Quote.create!(
      company: company, status: 'sent', subtotal: 1200, total: 1200,
      items: [
        { 'name' => 'Skirting', 'quantity' => 1, 'unit_price' => 1200, 'total' => 1200,
          'cost' => 640, 'unit_cost' => 640, 'margin' => 560, 'internal_notes' => 'vendor B' }
      ]
    )
  end

  def items_in(body)
    body.dig('quote', 'items') + body.dig('quote', 'lineItems')
  end

  it 'shows prices but never cost, margin or internal notes' do
    get "/q/#{quote.public_token}"

    expect(response).to have_http_status(:ok)
    items_in(response.parsed_body).each do |item|
      expect(item).to include('name' => 'Skirting', 'unitPrice' => 1200, 'total' => 1200)
      expect(item.keys.grep(/cost|margin|internal/i)).to be_empty
    end
  end

  it 'hides cost in the accept and reject responses too' do
    post "/q/#{quote.public_token}/accept"

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to match(/cost|margin/i)
  end

  it 'leaves the dealer view of the quote untouched' do
    expect(quote.as_json['items'].first).to include('cost' => 640, 'unitCost' => 640)
  end
end

# frozen_string_literal: true

require 'rails_helper'

# A quote from the Deal Sheet carries its buyer discounts and trade-in as
# credit lines. The PDF printed them as charges (the minus sign was dropped),
# and a dealer could not show the buyer totals only.
RSpec.describe 'Quote credits and totals only', type: :request do
  let(:company) { create(:company) }
  let(:items) do
    [{ 'description' => 'Peak 1456H22P01', 'quantity' => 1, 'unit_price' => 40_000, 'total' => 40_000, 'taxable' => true },
     { 'description' => 'Dealer savings', 'quantity' => 1, 'unit_price' => -1918.44, 'total' => -1918.44, 'taxable' => true }]
  end
  let(:quote) do
    Quote.create!(company: company, status: 'sent', subtotal: 38_081.56, tax: 0, total: 38_081.56, items: items)
  end

  def pdf_text(q) = PDF::Reader.new(StringIO.new(QuotePdfGenerator.new(q).generate)).pages.map(&:text).join("\n")

  it 'prints a credit as a credit, without +Tax' do
    text = pdf_text(quote)
    expect(text).to include('-$1,918.44')
    expect(text).not_to match(/Dealer savings \+Tax/)
    expect(text).to include('Peak 1456H22P01 +Tax')
  end

  it 'shows totals only: no line prices, credits summed as savings' do
    quote.update!(pricing_display: 'bundled')
    text = pdf_text(quote)
    expect(text).to include('Peak 1456H22P01', 'Savings', '-$1,918.44', '$38,081.56')
    expect(text).not_to include('Dealer savings', 'Unit Price', '+Tax')

    get "/q/#{quote.public_token}"
    body = response.parsed_body['quote']
    expect(body['items'].map { |i| i['description'] }).to eq(['Peak 1456H22P01'])
    expect(body['items'].first.keys.grep(/price|total|discount/i)).to be_empty
    expect(body).to include('savings' => 1918.44, 'itemsPrice' => 40_000.0)
  end

  it 'refuses an unknown display' do
    expect(quote.update(pricing_display: 'secret')).to be(false)
  end
end

# frozen_string_literal: true

require 'rails_helper'

# Invoice links customers get by email and text point at the app's own
# address from the brand kernel, never the old landlordinsight.com hosts.
RSpec.describe Invoice, type: :model do
  let(:company) { create(:company) }
  let(:location) { company.locations.first || company.locations.create!(name: 'Main') }
  let(:invoice) { company.invoices.create!(location: location, invoice_date: Date.current, status: 'draft') }

  it 'builds the pay and view links on the brand app address' do
    allow(Brand).to receive(:app_url).and_return('https://app.dealertide.com/')
    expect(invoice.payment_url).to eq("https://app.dealertide.com/pay/invoice/#{invoice.payment_token}")
    expect(invoice.public_url).to eq("https://app.dealertide.com/invoice/#{invoice.public_token}")
  end

  it 'never falls back to the old landlordinsight.com host' do
    expect(invoice.payment_url).not_to include('landlordinsight')
  end
end

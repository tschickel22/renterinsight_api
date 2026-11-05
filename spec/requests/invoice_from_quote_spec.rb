# frozen_string_literal: true

require 'rails_helper'

# Quote had no invoices association, so this action raised before it did anything,
# and it copied the quote's tax in dollars into the invoice's tax rate.
RSpec.describe 'Invoice from a quote', type: :request do
  let(:company) { create(:company) }
  let(:admin) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'U', last_name: 'Ser', password: 'Password123!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:contact) { Contact.create!(company: company, first_name: 'Hannah', last_name: 'Whitfield', email: 'hannah@example.com') }
  let(:location) { company.locations.create!(name: 'Denver') }
  let(:quote) do
    Quote.create!(company: company, contact: contact, location: location, status: 'accepted', subtotal: 1000, tax: 80, tax_rate: 8, total: 1080,
                  items: [{ 'description' => 'Skirting', 'quantity' => 2, 'unit_price' => 500, 'total' => 1000 }])
  end

  def auth = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(admin)}", 'X-Company-ID' => company.id.to_s }

  def convert = post('/api/v1/invoices/convert-from-quote', params: { quote_id: quote.id }, headers: auth)

  it 'makes an invoice with the quote lines and its tax rate' do
    convert

    expect(response).to have_http_status(:created), response.body
    invoice = company.invoices.find_by!(quote_id: quote.id)
    expect(invoice.tax_rate.to_f).to eq(8.0)
    expect(invoice.contact_id).to eq(contact.id)
    item = invoice.invoice_items.first
    expect([item.description, item.quantity.to_f, item.rate.to_f]).to eq(['Skirting', 2.0, 500.0])
    expect(invoice.reload.total.to_f).to eq(1080.0)
  end

  it 'will not make a second invoice from the same quote' do
    convert
    first = company.invoices.find_by!(quote_id: quote.id)

    convert

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body['existing_invoice_id']).to eq(first.id)
    expect(company.invoices.where(quote_id: quote.id).count).to eq(1)
  end
end

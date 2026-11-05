# frozen_string_literal: true

require 'rails_helper'

# A buyer accepting a quote leaves a date, a time and an address that both sides can see.
RSpec.describe 'Quote acceptance stamp', type: :request do
  let(:company) { create(:company) }
  let(:contact) { Contact.create!(company: company, first_name: 'Hannah', last_name: 'Whitfield', email: 'hannah@example.com') }
  let(:quote) { Quote.create!(company: company, contact: contact, status: 'sent', subtotal: 100, total: 100, items: []) }

  it 'stamps the address Cloudflare reports, not its own edge server' do
    post "/q/#{quote.public_token}/accept", headers: { 'CF-Connecting-IP' => '203.0.113.9', 'REMOTE_ADDR' => '172.68.34.118' }

    expect(response).to have_http_status(:ok)
    body = response.parsed_body['quote']
    expect(body).to include('status' => 'accepted', 'accepted_ip' => '203.0.113.9', 'accepted_via' => 'public_link',
                            'accepted_by_name' => 'Hannah Whitfield')
    expect(body['accepted_at']).to be_present
  end

  it 'shows the stamp to the buyer when they come back to the link' do
    quote.accept!(ip: '203.0.113.9', via: 'public_link', by: 'Hannah Whitfield')

    get "/q/#{quote.public_token}"

    expect(response.parsed_body['quote']).to include('accepted_ip' => '203.0.113.9', 'accepted_via' => 'public_link')
  end

  it 'falls back to the request address when the header is missing or is not an address' do
    post "/q/#{quote.public_token}/accept", headers: { 'CF-Connecting-IP' => 'not-an-ip', 'REMOTE_ADDR' => '198.51.100.4' }

    expect(quote.reload.accepted_ip).to eq('198.51.100.4')
  end

  it 'will not take an acceptance after the quote expired' do
    quote.update_columns(valid_until: Date.current - 1)

    post "/q/#{quote.public_token}/accept"

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.parsed_body).to include('expired' => true)
    expect(quote.reload.status).to eq('sent')
  end

  it 'still takes it on its last valid day' do
    quote.update_columns(valid_until: Date.current)

    post "/q/#{quote.public_token}/accept"

    expect(quote.reload.status).to eq('accepted')
  end

  it 'does not stamp a second time' do
    quote.accept!(ip: '203.0.113.9', via: 'public_link')

    post "/q/#{quote.public_token}/accept", headers: { 'CF-Connecting-IP' => '198.51.100.77' }

    expect(response).to have_http_status(:unprocessable_entity)
    expect(quote.reload.accepted_ip).to eq('203.0.113.9')
  end

  it 'says on the printed quote who accepted it, when and from where' do
    quote.accept!(ip: '203.0.113.9', via: 'public_link', by: 'Hannah Whitfield')

    summary = quote.acceptance_summary('America/Denver')

    expect(summary).to start_with('Accepted by Hannah Whitfield on ').and end_with('from IP 203.0.113.9')
    expect(QuotePdfGenerator.new(quote).generate).to start_with('%PDF')
  end

  it 'separates a dealer marking it accepted from the buyer accepting it' do
    quote.accept!(ip: '198.51.100.4', via: 'dealer', by: 'Alex Morgan')

    expect(quote.acceptance_summary).to start_with('Marked accepted by Alex Morgan')
  end
end

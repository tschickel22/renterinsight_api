# frozen_string_literal: true

require 'rails_helper'

# E87 retest 1.2: printing a second batch offered the last number already
# printed as the starting number, and the clash came back as a bare 422.
RSpec.describe 'Printed check numbers', type: :request do
  let(:company) { create(:company) }
  let(:admin) do
    User.create!(email: "ap-#{SecureRandom.hex(3)}@example.com", first_name: 'A', last_name: 'P', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let!(:bank) do
    BankAccount.create!(company: company, account_purpose: 'sync_only', account_type: 'credit_card', bank_name: 'First Bank',
                        is_active: true, check_printing_enabled: true, check_number: 1001)
  end

  def h = { 'Authorization' => "Bearer #{JsonWebToken.generate_access_token(admin)}", 'Content-Type' => 'application/json' }
  def body = JSON.parse(response.body)
  def queued(paid_to = 'Smith Set-Up') = company.printed_checks.create!(bank_account: bank, paid_to: paid_to, amount: 100, status: 'queued')

  def print!(checks, start)
    allow(CheckPrintingService).to receive(:generate_pdf_bytes).and_return('%PDF')
    post '/api/v1/printed_checks/print_batch', headers: h, params: { check_ids: checks.map(&:id), starting_check_number: start }.to_json
  end

  it 'offers the next number nobody has printed' do
    get '/api/v1/printed_checks/check_settings', headers: h
    expect(body['bank_accounts'].first['next_check_number']).to eq(1001)

    print!([queued, queued('Jones')], 1001)
    expect(response).to have_http_status(:ok), response.body

    get '/api/v1/printed_checks/check_settings', headers: h
    expect(body['bank_accounts'].first['next_check_number']).to eq(1003)
  end

  it 'refuses a batch that would reuse a number, in words, and prints none of it' do
    print!([queued], 1001)
    a = queued('Jones')
    b = queued('Brown')

    print!([a, b], 1000)
    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to eq('Check number 1001 has already been printed from First Bank. The next free number is 1002.')
    expect([a.reload.status, b.reload.status]).to eq(%w[queued queued])
  end
end

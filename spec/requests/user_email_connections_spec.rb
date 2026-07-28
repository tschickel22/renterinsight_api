# frozen_string_literal: true

require 'rails_helper'

# Covers the two ways a non-OAuth (SMTP) email connection failed to save.
RSpec.describe 'User email connections — SMTP saving', type: :request do
  let(:company) { create(:company) }
  let(:user) { User.create!(email: 'rep@example.com', password: 'Password123!', company: company, first_name: 'Rep', last_name: 'User') }
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}" } }

  let(:smtp_attrs) do
    {
      email_address: 'rep@example.com',
      display_name: 'Rep User',
      provider: 'smtp',
      smtp_host: 'smtp.example.com',
      smtp_port: 587,
      smtp_username: 'rep@example.com',
      smtp_password: 'super-secret-app-password'
    }
  end

  describe 'editing a connection without retyping the password' do
    it 'keeps the stored password when the form posts a blank one' do
      post '/api/v1/user-email-connections', params: { connection: smtp_attrs }, headers: headers
      expect(response).to have_http_status(:created)
      connection = UserEmailConnection.find(response.parsed_body.dig('connection', 'id'))
      expect(connection.smtp_password_encrypted).to eq('super-secret-app-password')

      # The edit form always sends smtp_password: '' — it never receives the real one.
      patch "/api/v1/user-email-connections/#{connection.id}",
            params: { connection: { display_name: 'Renamed', smtp_password: '' } },
            headers: headers

      expect(response).to have_http_status(:ok)
      connection.reload
      expect(connection.display_name).to eq('Renamed')
      expect(connection.smtp_password_encrypted).to eq('super-secret-app-password')
      expect(connection.smtp_credentials_valid?).to be(true)
    end

    it 'still takes a genuinely new password' do
      post '/api/v1/user-email-connections', params: { connection: smtp_attrs }, headers: headers
      connection = UserEmailConnection.find(response.parsed_body.dig('connection', 'id'))

      patch "/api/v1/user-email-connections/#{connection.id}",
            params: { connection: { smtp_password: 'rotated-password' } },
            headers: headers

      expect(connection.reload.smtp_password_encrypted).to eq('rotated-password')
    end
  end

  describe 'creating SMTP on a verified company domain' do
    before { company.update!(verified_email_domains: ['example.com']) }

    it 'keeps provider smtp instead of silently switching to company_domain' do
      post '/api/v1/user-email-connections', params: { connection: smtp_attrs }, headers: headers

      expect(response).to have_http_status(:created)
      connection = UserEmailConnection.find(response.parsed_body.dig('connection', 'id'))
      expect(connection.provider).to eq('smtp')
      expect(connection.to_smtp_settings).to include(address: 'smtp.example.com')
    end

    it 'still auto-verifies a non-SMTP address on the company domain' do
      post '/api/v1/user-email-connections',
           params: { connection: { email_address: 'rep@example.com', provider: 'company_domain' } },
           headers: headers

      connection = UserEmailConnection.find(response.parsed_body.dig('connection', 'id'))
      expect(connection.provider).to eq('company_domain')
      expect(connection).to be_verified
    end
  end
end

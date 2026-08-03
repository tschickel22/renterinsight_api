# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::CompanyDomains', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' } }

  describe 'DELETE /api/v1/company-domains/:id' do
    # One record serves the website and email independently. Destroying it outright took a
    # verified sending domain with it, which happened for real on staging: removing what
    # looked like a duplicate row from the website list deleted a domain that had been
    # through DNS verification. Re-verifying means republishing DNS, so this is expensive to
    # lose by accident.
    context 'when the domain is also verified for sending email' do
      let!(:domain) do
        company.company_domains.create!(
          hostname: 'dealer.example', web_enabled: true, email_enabled: true,
          email_verified_at: Time.current, ses_dkim_tokens: %w[a b c],
          ses_identity_status: 'SUCCESS'
        )
      end

      it 'keeps the record rather than destroying it' do
        delete "/api/v1/company-domains/#{domain.id}", headers: auth_headers

        expect(response).to have_http_status(:ok)
        expect(CompanyDomain.find_by(id: domain.id)).to be_present
      end

      it 'removes only the website role' do
        delete "/api/v1/company-domains/#{domain.id}", headers: auth_headers

        expect(domain.reload.web_enabled).to be false
        expect(domain.active).to be false
      end

      it 'leaves email sending verified and intact' do
        delete "/api/v1/company-domains/#{domain.id}", headers: auth_headers

        expect(domain.reload.email_enabled).to be true
        expect(domain.email_verified?).to be true
        expect(domain.ses_dkim_tokens).to eq(%w[a b c])
      end

      it 'says so, so the outcome is not a surprise' do
        delete "/api/v1/company-domains/#{domain.id}", headers: auth_headers

        expect(JSON.parse(response.body)['message']).to match(/still verified for sending/i)
      end
    end

    context 'when the domain is only used for the website' do
      let!(:domain) do
        company.company_domains.create!(hostname: 'web-only.example', web_enabled: true)
      end

      it 'destroys the record' do
        delete "/api/v1/company-domains/#{domain.id}", headers: auth_headers

        expect(response).to have_http_status(:ok)
        expect(CompanyDomain.find_by(id: domain.id)).to be_nil
      end
    end

    it 'will not touch another company\'s domain' do
      other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      foreign = other.company_domains.create!(hostname: 'not-yours.example', web_enabled: true)

      delete "/api/v1/company-domains/#{foreign.id}", headers: auth_headers

      expect(response).to have_http_status(:not_found)
      expect(CompanyDomain.find_by(id: foreign.id)).to be_present
    end
  end
end

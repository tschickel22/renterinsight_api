# frozen_string_literal: true

require 'rails_helper'

# The portal lives inside the main SPA: auth pages at the root, everything
# behind the login under /portalclient. These pin the links to routes that
# actually exist, because the previous ones concatenated onto PORTAL_URL and
# produced 404s nobody sees until a customer clicks one.
RSpec.describe BuyerPortalMailer, type: :mailer do
  let(:company) { Company.create!(name: "Dealer-#{SecureRandom.hex(3)}") }
  let(:buyer) do
    Contact.create!(company_id: company.id, first_name: 'B', last_name: 'Uyer',
                    email: "b-#{SecureRandom.hex(3)}@example.com")
  end
  let(:access) do
    BuyerPortalAccess.create!(buyer: buyer, company_id: company.id,
                              email: "p-#{SecureRandom.hex(3)}@example.com",
                              password: 'Password123!', password_confirmation: 'Password123!')
  end

  around do |example|
    original = ENV['PORTAL_URL']
    ENV['PORTAL_URL'] = 'https://app.dealertide.com'
    example.run
    ENV['PORTAL_URL'] = original
  end

  describe 'welcome_email' do
    it 'sends people to the portal login, not the staff app root' do
      body = described_class.welcome_email(access).body.to_s

      expect(body).to include('https://app.dealertide.com/client/login')
    end

    it 'links preferences to the portal settings page that exists' do
      body = described_class.welcome_email(access).body.to_s

      expect(body).to include('https://app.dealertide.com/portalclient/settings')
      expect(body).not_to include('/preferences')
    end
  end

  describe 'password_reset_email' do
    it 'uses the reset route the SPA actually serves' do
      access.generate_reset_token if access.respond_to?(:generate_reset_token)
      body = described_class.password_reset_email(access).body.to_s

      expect(body).to include('/client/reset-password/new?token=')
      expect(body).not_to include('/auth/reset-password')
    end
  end

  describe 'PORTAL_APP_URL' do
    it 'wins over the derived path, for a portal that ever gets its own host' do
      ENV['PORTAL_APP_URL'] = 'https://portal.example.com'

      body = described_class.welcome_email(access).body.to_s
      expect(body).to include('https://portal.example.com/settings')
    ensure
      ENV.delete('PORTAL_APP_URL')
    end
  end
end

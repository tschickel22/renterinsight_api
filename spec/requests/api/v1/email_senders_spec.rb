# frozen_string_literal: true

require 'rails_helper'

RSpec.describe "Api::V1::EmailSenders", type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(
      email: "u-#{SecureRandom.hex(4)}@example.com",
      first_name: "Tom", last_name: "Schickel",
      password: "Pass1234!", company_id: company.id,
      role: "platform_admin"
    )
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:auth_headers) { { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" } }

  def make_user_conn(u, attrs = {})
    UserEmailConnection.create!({
      user_id: u.id,
      company_id: u.company_id,
      provider: 'oauth_gmail',
      email_address: "#{SecureRandom.hex(4)}@example.com",
      display_name: "#{u.first_name} #{u.last_name}",
      is_active: true,
      oauth_provider: 'google'
    }.merge(attrs))
  end

  describe "GET /api/v1/email_senders" do
    it "returns 401 without auth" do
      get "/api/v1/email_senders"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns user_senders for current company only" do
      make_user_conn(user)

      other_company = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
      other_user = User.create!(email: "x-#{SecureRandom.hex(4)}@example.com", first_name: "O", last_name: "U",
                                password: "Pass1234!", company_id: other_company.id)
      make_user_conn(other_user)

      get "/api/v1/email_senders", headers: auth_headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["user_senders"].length).to eq(1)
      expect(body["user_senders"].first["from_identity_id"]).to eq(user.id)
    end

    it "marks current_user's connection as is_default and is_current_user" do
      make_user_conn(user)
      teammate = User.create!(email: "t-#{SecureRandom.hex(4)}@example.com", first_name: "Team", last_name: "Mate",
                              password: "Pass1234!", company_id: company.id)
      make_user_conn(teammate)

      get "/api/v1/email_senders", headers: auth_headers
      body = JSON.parse(response.body)
      mine = body["user_senders"].find { |s| s["from_identity_id"] == user.id }
      theirs = body["user_senders"].find { |s| s["from_identity_id"] == teammate.id }
      expect(mine["is_default"]).to eq(true)
      expect(mine["is_current_user"]).to eq(true)
      expect(theirs["is_default"]).to eq(false)
      expect(theirs["is_current_user"]).to eq(false)
    end

    it "excludes inactive user connections" do
      make_user_conn(user, is_active: false)
      get "/api/v1/email_senders", headers: auth_headers
      body = JSON.parse(response.body)
      expect(body["user_senders"]).to be_empty
    end

    it "returns sms_senders for active TwilioAccount only" do
      TwilioAccount.create!(company_id: company.id, sub_account_sid: "AC#{SecureRandom.hex(8)}",
                            auth_token: "tok-#{SecureRandom.hex(8)}",
                            phone_number: "+15555550100",
                            phone_number_sid: "PN#{SecureRandom.hex(8)}",
                            status: 'active')
      TwilioAccount.create!(company_id: company.id, sub_account_sid: "AC#{SecureRandom.hex(8)}",
                            auth_token: "tok-#{SecureRandom.hex(8)}",
                            phone_number: "+15555550101",
                            phone_number_sid: "PN#{SecureRandom.hex(8)}",
                            status: 'suspended')
      get "/api/v1/email_senders", headers: auth_headers
      body = JSON.parse(response.body)
      expect(body["sms_senders"].length).to eq(1)
      expect(body["sms_senders"].first["phone_number"]).to eq("+15555550100")
      expect(body["sms_senders"].first["from_identity_type"]).to eq("Company")
    end

    it "returns location_senders scoped to company" do
      loc = Location.create!(company_id: company.id, name: "Denver", code: "DEN-#{SecureRandom.hex(2)}", active: true)
      LocationEmailConnection.create!(location_id: loc.id, company_id: company.id,
                                      provider: 'oauth_gmail', email_address: "den@example.com",
                                      display_name: "Denver Sales", is_active: true,
                                      oauth_provider: 'google')

      get "/api/v1/email_senders", headers: auth_headers
      body = JSON.parse(response.body)
      expect(body["location_senders"].length).to eq(1)
      expect(body["location_senders"].first["from_identity_type"]).to eq("Location")
      expect(body["location_senders"].first["from_identity_id"]).to eq(loc.id)
    end

    it "returns company_senders scoped to company" do
      CompanyEmailConnection.create!(company_id: company.id, provider: 'oauth_gmail',
                                     email_address: "info@example.com", display_name: "Info",
                                     is_active: true, oauth_provider: 'google')

      get "/api/v1/email_senders", headers: auth_headers
      body = JSON.parse(response.body)
      expect(body["company_senders"].length).to eq(1)
      expect(body["company_senders"].first["from_identity_type"]).to eq("Company")
      expect(body["company_senders"].first["from_identity_id"]).to eq(company.id)
    end
  end
end

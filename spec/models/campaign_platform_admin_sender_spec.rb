# frozen_string_literal: true

require 'rails_helper'

# A platform admin works inside every tenant but belongs to one home company,
# so a campaign they set up to send as themselves resolved to nobody and failed
# every recipient (campaign 26, September 2026). Platform admins now resolve in
# any company; nobody else does.
RSpec.describe Campaign, 'sending as a platform admin' do
  let(:tenant) { Company.create!(name: "Tenant-#{SecureRandom.hex(3)}") }
  let(:home)   { Company.create!(name: "Home-#{SecureRandom.hex(3)}") }
  let(:admin) do
    User.create!(email: "admin-#{SecureRandom.hex(3)}@example.com", first_name: 'A', last_name: 'D',
                 password: 'Pass1234!', company_id: home.id, role: 'platform_admin')
  end

  def campaign_as(user)
    Campaign.create!(company_id: tenant.id, created_by_user_id: user.id, name: 'C', campaign_type: 'blast',
                     channel: 'email', from_identity_type: 'User', from_identity_id: user.id, throttle_per_day: 100)
  end

  it 'resolves a platform admin from another company as the sender' do
    expect(campaign_as(admin).identity_user).to eq(admin)
  end

  it "uses the admin's own mailbox when they have none in this company" do
    own = UserEmailConnection.create!(user_id: admin.id, company_id: home.id, provider: 'oauth_outlook',
                                      email_address: admin.email, is_active: true)

    expect(campaign_as(admin).resolve_email_connection_for_step).to eq(own)
  end

  it 'prefers a mailbox the admin connected in this company' do
    UserEmailConnection.create!(user_id: admin.id, company_id: home.id, provider: 'oauth_outlook',
                                email_address: admin.email, is_active: true)
    here = UserEmailConnection.create!(user_id: admin.id, company_id: tenant.id, provider: 'oauth_outlook',
                                       email_address: admin.email, is_active: true)

    expect(campaign_as(admin).resolve_email_connection_for_step).to eq(here)
  end

  it 'still refuses an ordinary user from another company' do
    outsider = User.create!(email: "o-#{SecureRandom.hex(3)}@example.com", first_name: 'O', last_name: 'U',
                            password: 'Pass1234!', company_id: home.id)
    UserEmailConnection.create!(user_id: outsider.id, company_id: home.id, provider: 'oauth_outlook',
                                email_address: outsider.email, is_active: true)
    c = campaign_as(outsider)

    expect(c.identity_user).to be_nil
    expect(c.resolve_email_connection_for_step).to be_nil
  end
end

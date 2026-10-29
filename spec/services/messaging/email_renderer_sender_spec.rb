# frozen_string_literal: true

require 'rails_helper'

# The sender card names the campaign's From user. A platform admin sending for
# another tenant is allowed a mailbox there, so the card must find them too.
RSpec.describe Messaging::EmailRenderer, '#resolve_sender_user' do
  let(:company) { Company.create!(name: 'Tenant') }
  let(:other)   { Company.create!(name: 'Elsewhere') }

  def user(company:, role:)
    User.create!(email: "s-#{SecureRandom.hex(4)}@example.com", first_name: 'S', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: role)
  end

  def resolve(from_id)
    campaign = double('Campaign', from_identity_type: 'User', from_identity_id: from_id)
    described_class.new(step: nil, recipient: nil, campaign: campaign, campaign_send: nil,
                        company: company, base_url: 'https://x.test').send(:resolve_sender_user)
  end

  it "finds a user in the campaign's company" do
    u = user(company: company, role: 'admin')
    expect(resolve(u.id)).to eq(u)
  end

  it 'finds a platform admin from another company' do
    u = user(company: other, role: 'platform_admin')
    expect(resolve(u.id)).to eq(u)
  end

  it 'does not find an ordinary user from another company' do
    u = user(company: other, role: 'admin')
    expect(resolve(u.id)).to be_nil
  end
end

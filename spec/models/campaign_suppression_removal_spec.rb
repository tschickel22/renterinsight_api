# frozen_string_literal: true

require 'rails_helper'

# A dealer may remove a suppression they added by hand, and nothing else. An
# unsubscribe, a STOP, a hard bounce and a spam complaint were all recorded by
# someone other than the dealer, and deleting one so the next campaign mails the
# person again is exactly what an opt-out exists to prevent.
RSpec.describe 'Removing a campaign suppression' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }

  def suppression(reason, email: nil)
    CampaignSuppression.create!(company_id: company.id, reason: reason,
                                email_address: email || "s-#{SecureRandom.hex(4)}@example.com")
  end

  %w[unsubscribe bounce_hard complaint].each do |reason|
    it "refuses to destroy a #{reason} row" do
      s = suppression(reason)

      expect(s.destroy).to be(false)
      expect(CampaignSuppression.exists?(s.id)).to be(true)
    end
  end

  it 'refuses to destroy an sms_stop row' do
    s = CampaignSuppression.create!(company_id: company.id, reason: 'sms_stop', phone_number: '+13035551234')

    expect(s.destroy).to be(false)
    expect(CampaignSuppression.exists?(s.id)).to be(true)
  end

  it 'allows a dealer-created manual row to be removed' do
    s = suppression('manual')

    expect(s.destroy).to be_truthy
    expect(CampaignSuppression.exists?(s.id)).to be(false)
  end

  # Texting START is the recipient lifting their own STOP, which is theirs to do.
  it 'lets the recipient lift their own STOP by texting START' do
    CampaignSuppression.create!(company_id: company.id, reason: 'sms_stop', phone_number: '+13035551234')

    Campaigns::SmsInboundHandler.handle_start(company.id, '+13035551234', nil)

    expect(CampaignSuppression.where(company_id: company.id, reason: 'sms_stop')).to be_empty
  end

  it 'says which reason blocked the removal' do
    s = suppression('unsubscribe')
    s.destroy

    expect(s.errors[:base].join).to match(/unsubscribe opt-out was recorded by the recipient/i)
  end
end

# The dealer-facing endpoint, which is where this rule is actually felt. The
# model guard alone passed its specs while `dealer_removable?` was private, so
# the controller would have raised NoMethodError on every call.
RSpec.describe 'DELETE /api/v1/campaign_suppressions/:id', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:admin) do
    User.create!(email: "a-#{SecureRandom.hex(4)}@example.com", first_name: 'A', last_name: 'D',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: admin.id, company_id: company.id)}" }
  end

  def suppression(reason)
    CampaignSuppression.create!(company_id: company.id, reason: reason,
                                email_address: "s-#{SecureRandom.hex(4)}@example.com")
  end

  it 'refuses to delete an unsubscribe and says why' do
    s = suppression('unsubscribe')

    delete "/api/v1/campaign_suppressions/#{s.id}", headers: headers

    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)['reason']).to eq('unsubscribe')
    expect(CampaignSuppression.exists?(s.id)).to be(true)
  end

  it 'deletes a manual row the dealer added themselves' do
    s = suppression('manual')

    delete "/api/v1/campaign_suppressions/#{s.id}", headers: headers

    expect(response).to have_http_status(:no_content)
    expect(CampaignSuppression.exists?(s.id)).to be(false)
  end
end

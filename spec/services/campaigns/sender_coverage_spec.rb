# frozen_string_literal: true

require 'rails_helper'

# Owner mode resolves a different mailbox for every recipient, so a campaign can
# start perfectly happily and then send nothing: reps who never connected a
# mailbox, and reps on Gmail, which campaign mail may not use. Refusing to start
# would be wrong, because one rep on Gmail must not stop a campaign for the four
# who are not. So it has to be said rather than blocked.
RSpec.describe Campaigns::SenderCoverage do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }

  def rep(provider: nil, email: nil)
    u = User.create!(email: email || "rep-#{SecureRandom.hex(3)}@dealer.example",
                     first_name: 'R', last_name: 'P', password: 'Pass1234!', company_id: company.id)
    if provider
      UserEmailConnection.create!(company_id: company.id, user_id: u.id, provider: provider,
                                  email_address: u.email, is_active: true)
    end
    u
  end

  def campaign_for(identity_type, identity_id = nil, waterfall: false)
    c = Campaign.create!(company_id: company.id, created_by_user_id: rep.id, name: 'W',
                         campaign_type: 'blast', channel: 'email',
                         from_identity_type: identity_type, from_identity_id: identity_id,
                         throttle_per_day: 100, email_waterfall: waterfall)
    c.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi',
                             body_blocks: [{ 'type' => 'text', 'html' => 'Hi' }])
    c
  end

  def enrol(campaign, owner)
    lead = Lead.create!(company_id: company.id, first_name: 'S', last_name: 'K',
                        owner_id: owner&.id, email: "l-#{SecureRandom.hex(4)}@example.com")
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: 'Lead',
                               recipient_id: lead.id, email_address_snapshot: lead.email, status: 'pending')
    lead
  end

  describe 'owner mode' do
    it 'separates usable senders, Gmail, and no mailbox at all' do
      c = campaign_for('Owner')
      enrol(c, rep(provider: 'oauth_outlook'))
      enrol(c, rep(provider: 'oauth_gmail'))
      enrol(c, rep)

      result = described_class.for_campaign(c)

      expect(result.total).to eq(3)
      expect(result.usable).to eq(1)
      expect(result.google).to eq(1)
      expect(result.missing).to eq(1)
      expect(result.blocked).to eq(2)
      expect(result).not_to be_all_covered
    end

    it 'names the owners so the warning can be acted on' do
      c = campaign_for('Owner')
      gmail_rep = rep(provider: 'oauth_gmail', email: 'sells@gmail.com')
      enrol(c, gmail_rep)

      owners = described_class.for_campaign(c).owners

      expect(owners.size).to eq(1)
      expect(owners.first[:reason]).to eq('google')
      expect(owners.first[:name]).to eq('sells@gmail.com')
      expect(owners.first[:count]).to eq(1)
    end

    it 'counts recipients per owner rather than resolving one mailbox per recipient' do
      c = campaign_for('Owner')
      shared = rep(provider: 'oauth_gmail')
      3.times { enrol(c, shared) }

      result = described_class.for_campaign(c)

      expect(result.google).to eq(3)
      expect(result.owners.size).to eq(1)
      expect(result.owners.first[:count]).to eq(3)
    end

    it 'reports a clear audience as covered' do
      c = campaign_for('Owner')
      enrol(c, rep(provider: 'oauth_outlook'))

      expect(described_class.for_campaign(c)).to be_all_covered
    end

    it 'treats a recipient with no owner as having no sender' do
      c = campaign_for('Owner')
      enrol(c, nil)

      expect(described_class.for_campaign(c).missing).to eq(1)
    end
  end

  describe 'a fixed sender' do
    it 'reports the whole audience blocked when that sender is Gmail' do
      sender = rep(provider: 'oauth_gmail', email: 'boss@gmail.com')
      c = campaign_for('User', sender.id)
      2.times { enrol(c, sender) }

      result = described_class.for_campaign(c)

      expect(result.fixed_sender).to be(true)
      expect(result.google).to eq(2)
      expect(result.owners.first[:name]).to eq('boss@gmail.com')
    end

    it 'reports it usable when the sender is not Gmail' do
      sender = rep(provider: 'oauth_outlook')
      c = campaign_for('User', sender.id)
      enrol(c, sender)

      expect(described_class.for_campaign(c)).to be_all_covered
    end
  end

  # A waterfall campaign always has a sender: location, then company, then
  # platform settings. Nothing to warn about.
  it 'never warns on a waterfall campaign' do
    c = campaign_for('Owner', nil, waterfall: true)
    enrol(c, rep)

    expect(described_class.for_campaign(c)).to be_all_covered
  end
end

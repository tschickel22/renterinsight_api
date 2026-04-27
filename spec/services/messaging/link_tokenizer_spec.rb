# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::LinkTokenizer do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'L',
                     campaign_type: 'blast', from_identity_type: 'User',
                     from_identity_id: user.id, throttle_per_day: 100)
  end
  let(:source) { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }
  let(:lead) { Lead.create!(company: company, source: source, first_name: 'Sam', last_name: 'K', email: 's@example.com') }
  let(:step) { campaign.campaign_steps.create!(position: 0, channel: 'email', subject: 'Hi', body_blocks: [{ 'type' => 'text', 'html' => 'x' }]) }
  let(:enrollment) do
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                               recipient_type: 'Lead', recipient_id: lead.id,
                               email_address_snapshot: 's@example.com', status: 'pending')
  end
  let(:campaign_send) { CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id, campaign_enrollment_id: enrollment.id) }
  let(:tokenizer) { described_class.new(campaign_send: campaign_send, base_url: 'https://app.test') }

  describe '#tokenize_html' do
    it 'replaces all <a href> URLs with /t/<token> redirects' do
      html = '<p>Hello <a href="https://example.com/page">click</a> and <a href="https://other.test/x">other</a></p>'
      out = tokenizer.tokenize_html(html)
      expect(out).to include('https://app.test/t/')
      expect(out).not_to include('https://example.com/page')
      expect(out).not_to include('https://other.test/x')
      expect(CampaignLinkToken.where(campaign_send_id: campaign_send.id).count).to eq(2)
    end

    it 'skips mailto: and tel: links' do
      html = '<p><a href="mailto:a@b.com">mail</a><a href="tel:+15555550100">call</a></p>'
      out = tokenizer.tokenize_html(html)
      expect(out).to include('mailto:a@b.com')
      expect(out).to include('tel:+15555550100')
      expect(CampaignLinkToken.where(campaign_send_id: campaign_send.id).count).to eq(0)
    end

    it 'skips already-tokenized links' do
      html = '<a href="https://app.test/t/abc">already</a>'
      out = tokenizer.tokenize_html(html)
      expect(out).to include('https://app.test/t/abc')
      expect(CampaignLinkToken.where(campaign_send_id: campaign_send.id).count).to eq(0)
    end
  end

  describe '#tokenize_text' do
    it 'replaces bare URLs in plain text' do
      text = "Check it out: https://homes.test/listing-1 — thanks!"
      out = tokenizer.tokenize_text(text)
      expect(out).to include('https://app.test/t/')
      expect(out).not_to include('https://homes.test/listing-1')
    end
  end
end

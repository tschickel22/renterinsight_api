# frozen_string_literal: true

require 'rails_helper'

# A campaign that both emails and texts reaches a person on either. Its audience used to
# keep only the emailable, so a lead with just a phone never got the texts.
RSpec.describe Audiences::FilterCompiler, 'email and text campaigns' do
  let(:company) { Company.create!(name: "FC-#{SecureRandom.hex(4)}") }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }

  def make_lead(attrs = {})
    Lead.create!({
      company: company, source: source,
      first_name: "F#{SecureRandom.hex(2)}", last_name: "L#{SecureRandom.hex(2)}",
      status: 'new'
    }.merge(attrs))
  end

  def compile(channel: 'mixed', acknowledged: false)
    described_class.new(
      company: company, source_type: 'Lead', filter_tree: {},
      channel: channel, sms_consent_acknowledged: acknowledged
    ).scope.pluck(:id)
  end

  let!(:email_only)       { make_lead(email: "a#{SecureRandom.hex(3)}@e.com") }
  let!(:phone_opted_in)   { make_lead(phone: '3035550101', opt_in_sms: true) }
  let!(:phone_not_opted)  { make_lead(phone: '3035550102', opt_in_sms: false) }
  let!(:neither)          { make_lead }
  let!(:bad_email_phone)  { make_lead(email: "b#{SecureRandom.hex(3)}@e.com", email_invalid: true, phone: '3035550103', opt_in_sms: true) }

  it 'keeps anyone reachable by email or by an opted-in phone' do
    expect(compile).to contain_exactly(email_only.id, phone_opted_in.id, bad_email_phone.id)
  end

  it 'counts any phone once written consent is acknowledged' do
    expect(compile(acknowledged: true))
      .to contain_exactly(email_only.id, phone_opted_in.id, phone_not_opted.id, bad_email_phone.id)
  end

  it 'still keeps an email-only campaign to the emailable' do
    expect(compile(channel: 'email')).to contain_exactly(email_only.id)
  end

  it 'respects the rest of the filter' do
    other = Source.create!(name: "Show-#{SecureRandom.hex(2)}", company_id: company.id)
    show_phone = make_lead(phone: '3035550104', opt_in_sms: true, source: other)
    ids = described_class.new(
      company: company, source_type: 'Lead', channel: 'mixed',
      filter_tree: { 'type' => 'and', 'children' => [{ 'field' => 'source_name', 'operator' => 'equals', 'value' => other.name }] }
    ).scope.pluck(:id)
    expect(ids).to contain_exactly(show_phone.id)
  end
end

RSpec.describe Campaign, '#audience_channel' do
  it 'is mixed when the active steps both email and text' do
    campaign = described_class.new(channel: 'email')
    allow(campaign).to receive(:active_step_channels).and_return(%w[email sms])
    expect(campaign.audience_channel).to eq('mixed')
    allow(campaign).to receive(:active_step_channels).and_return(%w[email])
    expect(campaign.audience_channel).to eq('email')
  end
end

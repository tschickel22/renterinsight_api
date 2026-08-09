# frozen_string_literal: true

require 'rails_helper'

# An audience is a list of people a campaign will email. Records it can never reach do not
# belong in it: they inflate the estimate the dealer is shown, and for the bounced ones every
# enrollment spends SES reputation to rediscover what the last bounce already established.
#
# These live in the compiler rather than in AudienceEnroller so that the count on the
# audience screen and the set that actually gets enrolled are produced by the same code.
RSpec.describe Audiences::FilterCompiler, 'email reachability' do
  let(:company) { Company.create!(name: "FC-#{SecureRandom.hex(4)}") }
  let(:source)  { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }

  def make_lead(attrs = {})
    Lead.create!({
      company: company, source: source,
      first_name: "F#{SecureRandom.hex(2)}",
      last_name: "L#{SecureRandom.hex(2)}",
      email: "lead#{SecureRandom.hex(4)}@e.com",
      status: 'new'
    }.merge(attrs))
  end

  def compile(channel: 'email')
    described_class.new(
      company: company, source_type: 'Lead', filter_tree: {}, channel: channel
    ).scope.pluck(:id)
  end

  it 'includes a lead with a normal address' do
    lead = make_lead
    expect(compile).to include(lead.id)
  end

  it 'excludes a lead with no email address' do
    reachable = make_lead
    make_lead(email: nil)
    expect(compile).to contain_exactly(reachable.id)
  end

  it 'excludes a lead whose email is an empty string' do
    reachable = make_lead
    make_lead(email: '')
    expect(compile).to contain_exactly(reachable.id)
  end

  it 'excludes a lead flagged email_invalid by a previous bounce' do
    reachable = make_lead
    make_lead(email_invalid: true)
    expect(compile).to contain_exactly(reachable.id)
  end

  it 'excludes an address suppressed for a hard bounce' do
    reachable = make_lead
    bounced = make_lead(email: 'dead@example.com')
    CampaignSuppression.create!(
      company_id: company.id, email_address: 'dead@example.com', reason: 'bounce_hard'
    )
    expect(compile).to contain_exactly(reachable.id)
    expect(compile).not_to include(bounced.id)
  end

  it 'excludes an address suppressed for a spam complaint' do
    reachable = make_lead
    make_lead(email: 'reporter@example.com')
    CampaignSuppression.create!(
      company_id: company.id, email_address: 'reporter@example.com', reason: 'complaint'
    )
    expect(compile).to contain_exactly(reachable.id)
  end

  # Suppressions are downcased on write while CRM addresses are stored as typed. Comparing
  # them without normalising let a mixed-case lead slip past the exclusion and be mailed
  # again, which is the exact failure this whole guard exists to prevent.
  it 'excludes a suppressed address regardless of the case it was typed in' do
    reachable = make_lead
    make_lead(email: 'Dead.Address@Example.COM')
    CampaignSuppression.create!(
      company_id: company.id, email_address: 'dead.address@example.com', reason: 'bounce_hard'
    )
    expect(compile).to contain_exactly(reachable.id)
  end

  # An unsubscribe is a marketing preference, and the campaign path already honours it
  # through its own suppression check. It is not evidence the mailbox is dead, so it must not
  # be conflated with one here.
  it 'keeps an address suppressed only as an unsubscribe out of the unmailable filter' do
    unsubscribed = make_lead(email: 'optout@example.com')
    CampaignSuppression.create!(
      company_id: company.id, email_address: 'optout@example.com', reason: 'unsubscribe'
    )
    expect(compile).to include(unsubscribed.id)
  end

  it 'scopes suppression to the company, so another tenant\'s bounce does not filter ours' do
    lead = make_lead(email: 'shared@example.com')
    other = Company.create!(name: "OC-#{SecureRandom.hex(4)}")
    CampaignSuppression.create!(
      company_id: other.id, email_address: 'shared@example.com', reason: 'bounce_hard'
    )
    expect(compile).to include(lead.id)
  end

  # An SMS campaign reaches people by phone. Filtering it on email would silently drop every
  # recipient who has a mobile number and no address.
  it 'does not apply the email filter to an SMS audience' do
    no_email = make_lead(email: nil)
    expect(compile(channel: 'sms')).to include(no_email.id)
  end
end

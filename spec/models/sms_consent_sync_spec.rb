# frozen_string_literal: true

require 'rails_helper'

# Two permissions were gating the same SMS send and neither knew about the other.
#
# The audience filter (CampaignAudience#scope_for_sms_compliance, AudienceEnroller)
# selects on the opt_in_sms COLUMN. CampaignSender gates on the marketing
# PREFERENCE. A recipient had to satisfy both, and nothing kept them in step, so
# whichever one a dealer's setup produced, the other silently excluded the person.
RSpec.describe 'SMS marketing consent and opt_in_sms' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:lead) do
    Lead.create!(company_id: company.id, first_name: 'S', last_name: 'K', email: 'sam@example.com')
  end

  def sms_pref(recipient)
    CommunicationPreference.find_or_create_for(
      recipient: recipient, channel: 'sms', category: 'marketing'
    )
  end

  it 'sets opt_in_sms when SMS marketing consent is given' do
    expect(lead.opt_in_sms).to be_falsey

    sms_pref(lead).opt_in!

    expect(lead.reload.opt_in_sms).to be(true)
  end

  it 'clears opt_in_sms when SMS marketing consent is withdrawn' do
    sms_pref(lead).opt_in!
    expect(lead.reload.opt_in_sms).to be(true)

    sms_pref(lead).opt_out!('stop')

    expect(lead.reload.opt_in_sms).to be(false)
  end

  # A transactional preference says nothing about marketing permission.
  it 'ignores a transactional SMS preference' do
    CommunicationPreference.find_or_create_for(
      recipient: lead, channel: 'sms', category: 'transactional'
    ).opt_in!

    expect(lead.reload.opt_in_sms).to be_falsey
  end

  it 'ignores an email marketing preference' do
    CommunicationPreference.find_or_create_for(
      recipient: lead, channel: 'email', category: 'marketing'
    ).opt_in!

    expect(lead.reload.opt_in_sms).to be_falsey
  end

  it 'works on a contact too, so conversion does not lose it' do
    contact = Contact.create!(company_id: company.id, first_name: 'S', last_name: 'K',
                              email: 'sam@example.com')

    sms_pref(contact).opt_in!

    expect(contact.reload.opt_in_sms).to be(true)
  end

  describe 'the two gates agreeing' do
    it 'puts a consenting lead in the SMS audience AND past the send gate' do
      sms_pref(lead).opt_in!

      # The audience filter reads the column.
      expect(Lead.where(id: lead.id).where(opt_in_sms: true)).to include(lead)
      # The sender reads the preference.
      expect(CommunicationPreference.marketing_consent?(recipient: lead, channel: 'sms')).to be(true)
    end
  end

  describe 'a form that maps a field to opt_in_sms instead of the consent box' do
    let(:form) do
      IntakeForm.create!(
        company_id: company.id, name: 'Quote', is_active: true, auto_create_lead: true,
        marketing_consent_enabled: false,
        schema: [
          { 'name' => 'email', 'type' => 'email', 'label' => 'Email', 'leadField' => 'email' },
          { 'name' => 'first_name', 'type' => 'text', 'label' => 'First', 'leadField' => 'first_name' },
          # The pre-existing way a dealer captures SMS permission: a checkbox
          # mapped straight onto the column the audience filter reads.
          { 'name' => 'opt_in_sms', 'type' => 'checkbox', 'label' => 'Text me',
            'leadField' => 'opt_in_sms' }
        ]
      )
    end

    it 'still records a preference, so the send gate does not skip them' do
      Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' }
      submission = form.intake_submissions.create!(
        data: { 'first_name' => 'Sam', 'email' => "s-#{SecureRandom.hex(3)}@example.com",
                'opt_in_sms' => true },
        ip_address: '203.0.113.5', user_agent: 'RSpec', submitted_at: Time.current
      )
      submission.create_lead_from_submission unless submission.lead_id
      submission.reload

      created = Lead.find(submission.lead_id)
      expect(created.opt_in_sms).to be(true)
      expect(CommunicationPreference.marketing_consent?(recipient: created, channel: 'sms')).to be(true)
    end
  end
end

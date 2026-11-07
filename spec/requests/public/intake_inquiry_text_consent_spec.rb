# frozen_string_literal: true

require 'rails_helper'

# Carriers rejected the Lead Assistant texting campaign (Twilio 30913) because
# one checkbox asked for marketing and for texts about the inquiry together.
# The two are now separate boxes with separate records.
RSpec.describe 'Public intake form inquiry text consent', type: :request do
  let(:company) { Company.create!(name: 'Summit Park Homes', industry: 'manufactured_housing') }
  let!(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:form) do
    IntakeForm.create!(company_id: company.id, name: 'Get a quote', is_active: true,
                       auto_create_lead: true,
                       schema: [{ 'name' => 'email', 'type' => 'email', 'label' => 'Email' }],
                       field_mappings: { 'email' => 'email', 'first_name' => 'first_name', 'phone' => 'phone' })
  end

  def submit(payload)
    post "/f/#{form.public_id}/submit",
         params: payload.to_json,
         headers: { 'CONTENT_TYPE' => 'application/json', 'HTTP_USER_AGENT' => 'Mozilla/5.0 (Test)' }
  end

  let(:base) { { 'first_name' => 'Sam', 'email' => 'sam@example.com', 'phone' => '3035551212' } }

  it 'asks the two questions separately, neither one about the other' do
    json = form.public_as_json
    inquiry = json['sms_consent']['text']
    marketing = json['marketing_consent']['text']

    expect(json['sms_consent']['enabled']).to be(true)
    expect(inquiry).to include('Summit Park Homes may text me about my inquiry', 'Reply STOP', 'HELP',
                               'not a condition of purchase')
    expect(inquiry).not_to match(SmsRegistration::CampaignContent::MARKETING_WORDS)
    expect(marketing).to include('marketing emails and texts', 'offers')
    expect(marketing).not_to match(/inquiry|appointment/i)
    expect(json['sms_consent'].keys).to include('privacy_url', 'terms_url')
  end

  it 'records inquiry text consent on the lead and a transactional preference, not marketing' do
    submit(base.merge('sms_consent' => true))

    expect(response).to have_http_status(:ok)
    submission = IntakeSubmission.last
    expect(submission.sms_consent).to be(true)
    expect(submission.sms_consent_text).to include('about my inquiry')
    expect(submission.marketing_consent).to be(false)

    lead = Lead.find(submission.lead_id)
    expect(lead.sms_inquiry_consent).to be(true)
    expect(lead.may_text_about_inquiry).to be(true)
    expect(lead.opt_in_sms).to be(false)
    expect(CommunicationPreference.marketing_consent?(recipient: lead, channel: 'sms')).to be(false)

    pref = CommunicationPreference.find_by(recipient: lead, channel: 'sms', category: 'transactional')
    expect(pref.opted_in).to be(true)
    expect(pref.compliance_metadata).to include('kind' => 'inquiry_texts', 'consent_version' => 'v1',
                                                'intake_submission_id' => submission.id)
  end

  it 'does not let marketing consent alone open inquiry texting on a new lead' do
    travel_to(Lead::INQUIRY_TEXT_CONSENT_SINCE + 1.hour) { submit(base.merge('marketing_consent' => true)) }

    lead = Lead.find(IntakeSubmission.last.lead_id)
    expect(lead.opt_in_sms).to be(true)
    expect(lead.sms_inquiry_consent).to be(false)
    expect(lead.may_text_about_inquiry).to be(false)
  end

  it 'still honors the old combined consent given before the boxes split' do
    lead = company.leads.create!(first_name: 'Old', phone: '3035550000', opt_in_sms: true,
                                 created_at: Lead::INQUIRY_TEXT_CONSENT_SINCE - 1.day)
    expect(lead.may_text_about_inquiry).to be(true)
  end

  it 'records nothing when the box is off on the form, whatever is posted' do
    form.update!(sms_consent_enabled: false)
    submit(base.merge('sms_consent' => true))

    expect(IntakeSubmission.last.sms_consent).to be(false)
    expect(Lead.find(IntakeSubmission.last.lead_id).sms_inquiry_consent).to be(false)
  end

  it 'versions the wording when a dealer edits it' do
    form.update!(sms_consent_text: 'Yes, {{company}} may text me about my visit.')
    expect(form.sms_consent_version).to eq('v2')
    expect(form.resolved_sms_consent_text).to eq('Yes, Summit Park Homes may text me about my visit.')
  end
end

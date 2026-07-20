# frozen_string_literal: true

require 'rails_helper'

# Covers the Share dialog's `?source_id=<id>` URL flow. When a public intake
# link is generated from the CRM Sources tab (source of truth), the URL carries
# the catalog Source id so the created Lead attributes to that exact Source —
# no title-casing, no duplicate Source rows, no override from the form's
# configured default.
RSpec.describe IntakeSubmission, 'source resolution priority', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:website_source) { Source.create!(company_id: company.id, name: 'Website Contact', is_active: true) }
  let(:google_source)  { Source.create!(company_id: company.id, name: 'Google Business', is_active: true) }
  let(:form) do
    IntakeForm.create!(
      company_id: company.id,
      name: 'Pre-Qual',
      schema: [{ 'name' => 'first_name', 'type' => 'text', 'leadField' => 'first_name' }],
      is_active: true,
      auto_create_lead: true,
      auto_create_activity: false,
      source_id: website_source.id
    )
  end

  it 'uses source_id from the URL over the form default and over utm_source' do
    submission = IntakeSubmission.create!(
      intake_form_id: form.id,
      data: {
        'first_name' => 'Alice',
        'email' => "alice-#{SecureRandom.hex(3)}@example.com",
        'source_id' => google_source.id,
        'utm_source' => 'facebook' # should be ignored when source_id is present
      }
    )
    lead = Lead.find(submission.lead_id)
    expect(lead.source_id).to eq(google_source.id)
  end

  it 'ignores source_id from another company (falls back to form default)' do
    other_company = Company.create!(name: "Other-#{SecureRandom.hex(4)}", industry: 'rv')
    other_source  = Source.create!(company_id: other_company.id, name: 'Foreign', is_active: true)

    submission = IntakeSubmission.create!(
      intake_form_id: form.id,
      data: {
        'first_name' => 'Bob',
        'email' => "bob-#{SecureRandom.hex(3)}@example.com",
        'source_id' => other_source.id
      }
    )
    lead = Lead.find(submission.lead_id)
    expect(lead.source_id).to eq(website_source.id)
  end

  it 'falls back to utm_source when no source_id is present' do
    submission = IntakeSubmission.create!(
      intake_form_id: form.id,
      data: {
        'first_name' => 'Carol',
        'email' => "carol-#{SecureRandom.hex(3)}@example.com",
        'utm_source' => 'google_business'
      }
    )
    lead = Lead.find(submission.lead_id)
    expect(lead.source.name).to eq('Google Business')
  end

  it 'falls back to the form default when no attribution params are present' do
    submission = IntakeSubmission.create!(
      intake_form_id: form.id,
      data: {
        'first_name' => 'Dan',
        'email' => "dan-#{SecureRandom.hex(3)}@example.com"
      }
    )
    lead = Lead.find(submission.lead_id)
    expect(lead.source_id).to eq(website_source.id)
  end
end

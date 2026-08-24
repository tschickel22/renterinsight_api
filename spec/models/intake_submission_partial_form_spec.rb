# frozen_string_literal: true

require 'rails_helper'

# An imported landing page keeps the design's own form markup, which is whatever
# the designer drew. Binding it to a CRM form that asks for more than the design
# collects is normal, not a mistake: a Facebook page asking three questions can
# feed a form that defines six.
#
# So a required field the design has no input for must never turn a real lead
# into a rejected submission. There is no server-side required validation today
# and this pins that, because adding one later would break every landing page
# quietly and only in production.
RSpec.describe IntakeSubmission, 'a form asking for more than the page collects', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:source) { Source.create!(company_id: company.id, name: 'Facebook', is_active: true) }

  # Four required fields; the design below sends three keys, none of them by
  # these names.
  let(:form) do
    IntakeForm.create!(
      company_id: company.id, name: 'Facebook Contact', is_active: true,
      auto_create_lead: true, auto_create_activity: false, source_id: source.id,
      schema: [
        { 'name' => 'First Name', 'type' => 'text', 'leadField' => 'first_name', 'required' => true },
        { 'name' => 'Last Name', 'type' => 'text', 'leadField' => 'last_name', 'required' => true },
        { 'name' => 'Email', 'type' => 'email', 'leadField' => 'email', 'required' => true },
        { 'name' => 'Number of Locations', 'type' => 'text', 'required' => true }
      ]
    )
  end

  # What an imported design actually posts.
  let(:design_payload) do
    { 'name' => 'Thomas M Schickel', 'email' => "t-#{SecureRandom.hex(3)}@example.com",
      'phone' => '3035551234', 'source' => 'landing_page_design' }
  end

  it 'accepts the submission' do
    submission = IntakeSubmission.new(intake_form_id: form.id, data: design_payload)

    expect(submission.save).to be true
  end

  it 'still creates the lead' do
    submission = IntakeSubmission.create!(intake_form_id: form.id, data: design_payload)

    expect(submission.lead_id).to be_present
  end

  # The design's field names match none of the form's, so explicit mapping never
  # fires and smart detection does the work. A full name splits on the first
  # space.
  it 'fills the contact fields the design did send' do
    submission = IntakeSubmission.create!(intake_form_id: form.id, data: design_payload)
    lead = Lead.find(submission.lead_id)

    expect(lead.first_name).to eq('Thomas')
    expect(lead.last_name).to eq('M Schickel')
    expect(lead.email).to eq(design_payload['email'])
    expect(lead.phone).to eq('3035551234')
  end

  # The reason the binding matters at all: attribution.
  it 'attributes the lead to the bound form source' do
    submission = IntakeSubmission.create!(intake_form_id: form.id, data: design_payload)

    expect(Lead.find(submission.lead_id).source_id).to eq(source.id)
  end

  it 'leaves a required field the design never collected simply empty' do
    submission = IntakeSubmission.create!(intake_form_id: form.id, data: design_payload)

    expect(submission.data).not_to have_key('Number of Locations')
  end
end

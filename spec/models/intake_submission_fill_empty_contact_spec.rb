# frozen_string_literal: true

require 'rails_helper'

# Covers Issue #1: when an intake submission matches an existing Contact
# (Case B in intake_submission.rb), the empty fields on that Contact should
# be filled in from the submission — mirroring the fill-empty merge that
# absorb_into_existing_lead already does for existing leads.
RSpec.describe IntakeSubmission, '#attach_inquiry_to_existing (fill-empty contact merge)', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:contact) do
    Contact.create!(company_id: company.id, first_name: 'Tom', last_name: 'Test',
                    email: 'tom@example.com', phone: '3035709810')
  end
  let(:form) do
    IntakeForm.create!(company_id: company.id, name: 'Pre-Qual', schema: [], is_active: true,
                       auto_create_lead: true, auto_create_activity: false)
  end
  let(:submission) { IntakeSubmission.create!(intake_form_id: form.id, data: {}) }
  let(:match) { IdentityResolver::Match.new(type: :contact, record: contact, matched: :phone, converted: nil) }

  it 'fills empty fields on the contact from the submission (never overwriting good data)' do
    lead_data = {
      company_id: company.id, source_id: nil, status: 'new', location_id: nil, owner_id: nil,
      first_name: 'Tom',       # matches existing — no-op
      last_name:  'DIFFERENT', # conflict — must NOT overwrite
      street:     '123 Elm St',
      city:       'Denver',
      state:      'CO',
      zip:        '80207'
    }

    submission.attach_inquiry_to_existing(match, lead_data, {}, {}, form)

    contact.reload
    expect(contact.street).to eq('123 Elm St')
    expect(contact.city).to  eq('Denver')
    expect(contact.state).to eq('CO')
    expect(contact.zip).to   eq('80207')
    expect(contact.last_name).to eq('Test') # existing value preserved, not overwritten
    expect(contact.email).to eq('tom@example.com') # untouched, was already set
  end

  it 'writes a note capturing what was filled and any conflicts' do
    lead_data = { last_name: 'DIFFERENT', city: 'Denver' }
    submission.attach_inquiry_to_existing(match, lead_data, {}, {}, form)

    note = Note.where(entity_type: 'Contact', entity_id: contact.id).order(created_at: :desc).first
    expect(note).to be_present
    expect(note.content).to include('EXISTING CUSTOMER INQUIRY')
    expect(note.content).to include('FILLED EMPTY FIELDS').and include('City')
    expect(note.content).to include('CONFLICTING VALUES').and include('Last name')
    expect(note.content).to include('kept "Test"').and include('"DIFFERENT"')
  end
end

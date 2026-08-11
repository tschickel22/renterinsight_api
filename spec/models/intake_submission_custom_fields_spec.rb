# frozen_string_literal: true

require 'rails_helper'

# The intake form builder's "Map to CRM Lead Field" list only ever offered the
# eleven hardcoded standard columns, so a dealer collecting "Are you wanting to
# finance or buy in cash?" had nowhere to put the answer and it survived only as
# free text in the lead's notes. Evangeline has 28 lead custom fields.
#
# Mapping to one has to route into the custom_field_values JSONB: assigning it
# as an attribute raises UnknownAttributeError on Lead.create! and loses the
# whole submission, not just the one answer.
RSpec.describe IntakeSubmission, 'custom field mapping', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  let!(:finance_field) do
    company.custom_fields.create!(module: 'leads', name: 'Finance or Cash', field_key: 'finance_or_cash',
                                  field_type: 'text', is_active: true)
  end

  def build_form(fields)
    IntakeForm.create!(company_id: company.id, name: 'Pre-Qual', schema: fields, is_active: true,
                       auto_create_lead: true, auto_create_activity: false)
  end

  def submit(form, data)
    sub = IntakeSubmission.create!(intake_form_id: form.id, data: data)
    sub.create_lead_from_submission
    sub
  end

  it 'writes a mapped custom answer into custom_field_values, not an attribute' do
    form = build_form([
      { 'name' => 'fname',   'type' => 'text', 'leadField' => 'first_name' },
      { 'name' => 'funding', 'type' => 'text', 'leadField' => 'custom:finance_or_cash' }
    ])

    submit(form, { 'fname' => 'Rylee', 'funding' => 'Financing' })

    lead = company.leads.order(:id).last
    expect(lead.first_name).to eq('Rylee')
    expect(lead.custom_field_values['finance_or_cash']).to eq('Financing')
  end

  it 'uses string keys so the JSONB round-trips' do
    form = build_form([
      { 'name' => 'fname',   'type' => 'text', 'leadField' => 'first_name' },
      { 'name' => 'funding', 'type' => 'text', 'leadField' => 'custom:finance_or_cash' }
    ])
    submit(form, { 'fname' => 'Rylee', 'funding' => 'Cash' })

    stored = company.leads.order(:id).last.reload.custom_field_values
    expect(stored.keys).to all(be_a(String))
    expect(stored['finance_or_cash']).to eq('Cash')
  end

  # Company 17 has a lead custom field keyed `email`, which is also a real Lead
  # column. Without the namespace the two mappings collide and whichever the UI
  # listed last silently wins.
  it 'keeps a custom field whose key shadows a real column out of the column' do
    company.custom_fields.create!(module: 'leads', name: 'Main App Email', field_key: 'email',
                                  field_type: 'email', is_active: true)

    form = build_form([
      { 'name' => 'primary_email', 'type' => 'email', 'leadField' => 'email' },
      { 'name' => 'app_email',     'type' => 'email', 'leadField' => 'custom:email' }
    ])

    submit(form, { 'primary_email' => 'real@example.com', 'app_email' => 'shadow@example.com' })

    lead = company.leads.order(:id).last
    expect(lead.email).to eq('real@example.com')
    expect(lead.custom_field_values['email']).to eq('shadow@example.com')
  end

  it 'still routes unmapped answers to unmapped_data rather than custom fields' do
    form = build_form([
      { 'name' => 'fname', 'type' => 'text', 'leadField' => 'first_name' },
      { 'name' => 'stray', 'type' => 'text' }
    ])
    submit(form, { 'fname' => 'Rylee', 'stray' => 'no mapping here' })

    lead = company.leads.order(:id).last
    expect(lead.custom_field_values).to be_blank
  end

  # A repeat inquiry absorbs into the existing lead via MergeHelper.fill_empty.
  # custom_field_values is a bag of many answers, not one value, so treating it
  # as a single attribute meant a lead holding ANY custom answer counted as
  # "not blank" and every new answer was dropped as one whole-hash conflict.
  describe 'a repeat submission from the same person' do
    let!(:county_field) do
      company.custom_fields.create!(module: 'leads', name: 'Lot County', field_key: 'lot_county',
                                    field_type: 'text', is_active: true)
    end

    it 'fills custom answers the existing lead does not have yet' do
      form = build_form([
        { 'name' => 'email',   'type' => 'email', 'leadField' => 'email' },
        { 'name' => 'funding', 'type' => 'text',  'leadField' => 'custom:finance_or_cash' },
        { 'name' => 'county',  'type' => 'text',  'leadField' => 'custom:lot_county' }
      ])

      submit(form, { 'email' => 'repeat@example.com', 'funding' => 'Financing' })
      submit(form, { 'email' => 'repeat@example.com', 'county' => 'St. Landry' })

      leads = company.leads.where(email: 'repeat@example.com')
      expect(leads.count).to eq(1)

      values = leads.first.reload.custom_field_values
      expect(values['finance_or_cash']).to eq('Financing') # from the first
      expect(values['lot_county']).to eq('St. Landry')     # filled by the second
    end

    it 'never overwrites a custom answer the lead already has' do
      form = build_form([
        { 'name' => 'email',   'type' => 'email', 'leadField' => 'email' },
        { 'name' => 'funding', 'type' => 'text',  'leadField' => 'custom:finance_or_cash' }
      ])

      submit(form, { 'email' => 'repeat@example.com', 'funding' => 'Financing' })
      submit(form, { 'email' => 'repeat@example.com', 'funding' => 'Cash' })

      lead = company.leads.find_by(email: 'repeat@example.com')
      expect(lead.reload.custom_field_values['finance_or_cash']).to eq('Financing')
    end
  end

  it 'maps address sub-fields to custom fields too' do
    company.custom_fields.create!(module: 'leads', name: 'Lot County', field_key: 'lot_county',
                                  field_type: 'text', is_active: true)

    form = build_form([
      { 'name' => 'fname', 'type' => 'text', 'leadField' => 'first_name' },
      {
        'name' => 'addr', 'type' => 'address',
        'leadFieldMap' => { 'street' => 'street', 'city' => 'custom:lot_county' }
      }
    ])

    submit(form, { 'fname' => 'Rylee', 'addr' => { 'street' => '2397 Bayou rd', 'city' => 'Port Barre' } })

    lead = company.leads.order(:id).last
    expect(lead.street).to eq('2397 Bayou rd')
    expect(lead.custom_field_values['lot_county']).to eq('Port Barre')
  end
end

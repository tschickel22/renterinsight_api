# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Websites::DefaultLeadForm do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }

  # A form with no fields renders as an empty box, so schema presence matters.
  SCHEMA = [{ 'id' => 'f1', 'label' => 'Email', 'type' => 'text', 'leadField' => 'email' }].freeze

  def form(name, active: true, schema: SCHEMA, created_at: Time.current)
    company.intake_forms.create!(name: name, is_active: active, schema: schema,
                                 created_at: created_at)
  end

  it 'is nil for a company with no forms' do
    expect(described_class.for(company)).to be_nil
  end

  it 'is nil for no company' do
    expect(described_class.for(nil)).to be_nil
  end

  it 'prefers a form that reads as general purpose' do
    form('Facebook Lead Intake', created_at: 3.days.ago)
    contact = form('Contact Us', created_at: 1.day.ago)

    expect(described_class.for(company)).to eq(contact)
  end

  it 'recognises other general-purpose wordings' do
    form('Spring Sale Event', created_at: 3.days.ago)
    general = form('Request Information', created_at: 1.day.ago)

    expect(described_class.for(company)).to eq(general)
  end

  # The demo lot's real state: four active forms, every one campaign-specific.
  # Showing "New Home Sales Special — Lowest Prices in East Texas" as the
  # contact form on a prospect's preview reads as someone else's marketing, but
  # a working form still beats "Contact form not available".
  it 'falls back to the least campaign-shaped form' do
    form('Google Test', created_at: 4.days.ago)
    form('Facebook Lead Intake', created_at: 3.days.ago)
    plain = form('Website Enquiries', created_at: 2.days.ago)

    expect(described_class.for(company)).to eq(plain)
  end

  it 'takes the oldest campaign form when every form is campaign-shaped' do
    oldest = form('Google Test', created_at: 4.days.ago)
    form('Facebook Lead Intake', created_at: 3.days.ago)

    expect(described_class.for(company)).to eq(oldest)
  end

  it 'ignores inactive forms' do
    form('Contact Us', active: false)

    expect(described_class.for(company)).to be_nil
  end

  # An empty form looks more broken than no form at all.
  it 'ignores a form with no fields' do
    form('Contact Us', schema: [])

    expect(described_class.for(company)).to be_nil
  end

  it 'does not reach across companies' do
    other = Company.create!(name: "Other-#{SecureRandom.hex(3)}")
    other.intake_forms.create!(name: 'Contact Us', is_active: true, schema: SCHEMA)

    expect(described_class.for(company)).to be_nil
  end
end

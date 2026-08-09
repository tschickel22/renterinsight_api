# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Concierge::LeadCapture do
  let(:company) { Company.create!(name: 'Summit Park Homes') }
  let(:location) { company.locations.create!(name: 'Showroom') }
  let(:website) do
    Website.create!(company_id: company.id, location_id: location.id, name: 'Summit',
                    slug: "s-#{SecureRandom.hex(4)}", status: 'published')
  end

  # Mirrors DefaultLeadForm::BASIC_FIELDS, which is what a generated site gets.
  def build_form(fields: nil, **attrs)
    company.intake_forms.create!(
      name: 'Contact Us',
      fields: fields || [
        { 'name' => 'First Name', 'type' => 'text', 'required' => true, 'lead_field' => 'first_name' },
        { 'name' => 'Email', 'type' => 'email', 'required' => true, 'lead_field' => 'email' },
        { 'name' => 'Message', 'type' => 'textarea', 'required' => false, 'lead_field' => 'notes' }
      ],
      auto_create_lead: true,
      **attrs
    )
  end

  subject(:capture) { described_class.new(company: company, website: website, form: form) }

  let(:form) { build_form }

  describe 'whether the chat can finish the job' do
    it 'can, for an ordinary contact form' do
      expect(capture.available?).to be(true)
    end

    # A dealer who turned CAPTCHA on did it to stop exactly this kind of
    # unattended submission, and Turnstile cannot be solved in a chat bubble.
    it 'cannot when the form demands a CAPTCHA' do
      expect(described_class.new(company: company, form: build_form(captcha_required: true)))
        .not_to be_available
    end

    it 'cannot when the dealer switched off automatic lead creation' do
      expect(described_class.new(company: company, form: build_form(auto_create_lead: false)))
        .not_to be_available
    end

    # A dealer who made "trade-in year" mandatory gets their form, not a lead
    # missing the one field they said they needed.
    it 'cannot when a required field is something a chat never asked' do
      picky = build_form(fields: [
                           { 'name' => 'Email', 'required' => true, 'lead_field' => 'email' },
                           { 'name' => 'Trade In Year', 'required' => true, 'lead_field' => 'trade_in_year' }
                         ])
      service = described_class.new(company: company, form: picky)

      expect(service).not_to be_available
      expect(service.unsatisfiable_required_fields).to eq(['trade_in_year'])
    end

    it 'is untroubled by optional fields it cannot supply' do
      relaxed = build_form(fields: [
                             { 'name' => 'Email', 'required' => true, 'lead_field' => 'email' },
                             { 'name' => 'Trade In Year', 'required' => false, 'lead_field' => 'trade_in_year' }
                           ])

      expect(described_class.new(company: company, form: relaxed)).to be_available
    end
  end

  describe 'creating the lead' do
    it 'creates one from a name and an email' do
      result = capture.call(visitor: { name: 'Jane Doe', email: 'jane@example.com' })

      expect(result.status).to eq('created')
      expect(Lead.find(result.lead_id)).to have_attributes(first_name: 'Jane', email: 'jane@example.com')
    end

    it 'refuses when it has a name but no way to reach them' do
      expect(capture.call(visitor: { name: 'Jane Doe' }).status).to eq('incomplete')
    end

    it 'refuses when it has contact details but no name' do
      expect(capture.call(visitor: { email: 'jane@example.com' }).status).to eq('incomplete')
    end

    it 'hands off to the form rather than half-filling a lead' do
      picky = described_class.new(company: company, form: build_form(captcha_required: true))
      result = picky.call(visitor: { name: 'Jane Doe', email: 'jane@example.com' })

      expect(result.status).to eq('form_required')
      expect(result.form_path).to eq('/contact')
    end
  end

  describe 'consent' do
    # The number is the part that carries the exposure, and it is the dealer's
    # exposure, not ours.
    it 'drops the phone number when the consent line was not accepted' do
      result = capture.call(visitor: { name: 'Jane Doe', email: 'jane@example.com', phone: '555-1234' },
                            consented: false)
      lead = Lead.find(result.lead_id)

      expect(result.status).to eq('created')
      expect(lead.phone).to be_blank
      expect(lead.email).to eq('jane@example.com')
    end

    it 'keeps it once they have accepted, and records what they agreed to' do
      result = capture.call(visitor: { name: 'Jane Doe', phone: '555-1234' }, consented: true)
      submission = form.intake_submissions.order(:id).last

      expect(Lead.find(result.lead_id).phone).to eq('555-1234')
      expect(submission.data['sms_consent']).to be(true)
      expect(submission.data['sms_consent_text']).to include('Reply STOP to opt out')
      expect(submission.data['sms_consent_at']).to be_present
    end

    it 'names the dealer in the wording, since it is their permission being given' do
      expect(capture.consent_text).to include('Summit Park Homes')
    end
  end

  describe 'what the salesperson reads' do
    it 'carries the questions they actually asked' do
      capture.call(
        visitor: { name: 'Jane Doe', email: 'jane@example.com' },
        intent: 'callback',
        transcript: [{ 'role' => 'user', 'content' => '3 bed under 90k' },
                     { 'role' => 'assistant', 'content' => 'Here are two.' },
                     { 'role' => 'user', 'content' => 'can you deliver to Weatherford?' }]
      )
      message = form.intake_submissions.order(:id).last.data['message']

      expect(message).to include('Asked for a callback through the website assistant.')
      expect(message).to include('3 bed under 90k')
      expect(message).to include('deliver to Weatherford')
      expect(message).not_to include('Here are two.')
    end

    # Without this a chat lead is indistinguishable from someone who filled in
    # the form, and the assistant can never be shown to have paid for itself.
    it 'attributes the lead to the assistant' do
      capture.call(visitor: { name: 'Jane Doe', email: 'jane@example.com' })

      expect(form.intake_submissions.order(:id).last.data)
        .to include('utm_source' => 'website_assistant', 'utm_medium' => 'chat')
    end
  end
end

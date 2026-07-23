# frozen_string_literal: true

require 'rails_helper'

# Regression cover for the Evangeline report: "why did Troy send me a lead
# captured by MY intake form?"
#
# The recipient was always correct — the form's notified_user got the lead. What
# was wrong was the SENDER. `send_intake_lead_email` passed `user:` (the
# recipient) into CommunicationService, which put them at the top of the sender
# waterfall. The notified rep had no personal mailbox connected, so resolution
# fell through to the company config — which held one individual's OAuth
# mailbox. Every lead alert at that dealer therefore appeared to be sent by that
# person.
#
# Two invariants locked in here:
#   1. exactly one recipient, the form's notified_user
#   2. no `user:` / `sent_by:` — sender is Location → Company → Platform only
RSpec.describe IntakeSubmission, 'new-lead notification targeting', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  def make_user(label)
    User.create!(email: "#{label}-#{SecureRandom.hex(4)}@example.com", first_name: label.capitalize,
                 last_name: 'Rep', password: 'Pass1234!', company_id: company.id, role: 'sales_rep')
  end

  let!(:notified) { make_user('hayden') }
  let!(:bystander) { make_user('troy') }

  let(:form) do
    IntakeForm.create!(
      company_id: company.id,
      name: 'Contact Us - Panama City',
      schema: [{ 'name' => 'first_name', 'type' => 'text', 'leadField' => 'first_name' }],
      is_active: true,
      auto_create_lead: true,
      auto_create_activity: true,
      notified_user_id: notified.id
    )
  end

  before { allow(CommunicationService).to receive(:send_email).and_return(nil) }

  def submit!
    IntakeSubmission.create!(
      intake_form_id: form.id,
      data: { 'first_name' => 'Frederick', 'email' => "f-#{SecureRandom.hex(3)}@example.com" }
    )
  end

  it 'emails only the notified user, never other reps at the company' do
    submit!

    expect(CommunicationService).to have_received(:send_email).once
    expect(CommunicationService).to have_received(:send_email).with(hash_including(to: notified.email))
    expect(CommunicationService).not_to have_received(:send_email).with(hash_including(to: bystander.email))
  end

  it 'does not route the sender through the recipient' do
    submit!

    expect(CommunicationService).to have_received(:send_email) do |args|
      expect(args).not_to have_key(:user)
      expect(args).not_to have_key(:sent_by)
    end
  end

  it 'assigns the lead to the notified user and files the activity to them alone' do
    submission = submit!
    lead = Lead.find(submission.lead_id)

    expect(lead.owner_id).to eq(notified.id)

    activities = LeadActivity.where(lead_id: lead.id)
    expect(activities.pluck(:assigned_to_id).uniq).to eq([notified.id])
  end
end

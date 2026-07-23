# frozen_string_literal: true

require 'rails_helper'

# Covers Issue #2: for existing-customer inquiries the notification should
# route TO the record's OWNER, not the form's fixed notified_user. And the
# Communication row should attach to the rep, not to the customer record
# (which was confusing — a failed rep-notification looked like a failed
# email TO the customer).
#
# Routing the RECIPIENT by owner is still correct. Routing the SENDER by owner
# is not, and was removed: `user:` put the recipient at the top of the sender
# waterfall, so the From address depended on whether that rep had a personal
# mailbox connected. Reps ended up receiving lead alerts that appeared to come
# from a coworker's inbox. Sender now resolves Location → Company → Platform.
RSpec.describe IntakeSubmission, '#notify_existing_customer_inquiry (owner-first routing)', type: :model do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:owner_user) do
    User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", first_name: 'Owner', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep')
  end
  let(:form_notified_user) do
    User.create!(email: "notified-#{SecureRandom.hex(4)}@example.com", first_name: 'Form', last_name: 'Notified',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep')
  end
  let(:contact) do
    Contact.create!(company_id: company.id, first_name: 'Tom', last_name: 'Test',
                    email: 'tom@example.com', phone: '3035709810', owner_id: owner_user.id)
  end
  let(:form) do
    IntakeForm.create!(company_id: company.id, name: 'Pre-Qual', schema: [], is_active: true,
                       auto_create_lead: true, auto_create_activity: true,
                       notified_user_id: form_notified_user.id)
  end
  let(:submission) { IntakeSubmission.create!(intake_form_id: form.id, data: {}) }
  let(:match) { IdentityResolver::Match.new(type: :contact, record: contact, matched: :phone, converted: nil) }

  before do
    # Stub the actual send so we can capture the invocation without hitting SES
    allow(CommunicationService).to receive(:send_email).and_return(nil)
  end

  it 'notifies the CONTACT OWNER when one is set (overrides form.notified_user)' do
    submission.notify_existing_customer_inquiry(match, form)

    expect(CommunicationService).to have_received(:send_email).with(
      hash_including(to: owner_user.email, communicable: owner_user)
    )
  end

  it 'falls back to form.notified_user when the contact has no owner' do
    contact.update!(owner_id: nil)

    submission.notify_existing_customer_inquiry(match, form)

    expect(CommunicationService).to have_received(:send_email).with(
      hash_including(to: form_notified_user.email, communicable: form_notified_user)
    )
  end

  it 'does NOT send as the recipient — sender resolves company/platform, never the rep' do
    submission.notify_existing_customer_inquiry(match, form)

    expect(CommunicationService).to have_received(:send_email) do |args|
      expect(args).not_to have_key(:user)
      expect(args).not_to have_key(:sent_by)
    end
  end

  it 'sends nothing when neither owner nor form notified_user is set' do
    contact.update!(owner_id: nil)
    form.update!(notified_user_id: nil)

    submission.notify_existing_customer_inquiry(match, form)

    expect(CommunicationService).not_to have_received(:send_email)
  end
end

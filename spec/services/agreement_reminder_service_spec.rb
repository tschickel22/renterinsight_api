# frozen_string_literal: true

require 'rails_helper'

# Automatic signing reminders were never scheduled and, when called, marked
# themselves sent without sending. They now go through the same job the Remind
# buttons use, and are limited so agreements left out for months stay quiet.
RSpec.describe AgreementReminderService do
  let(:company) { Company.create!(name: "Reminder Co #{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Rita', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin')
  end
  let(:agreement) do
    company.agreements.create!(title: 'Purchase Agreement', status: 'sent', delivery_method: 'both',
                               prepared_by: user, sent_at: 4.days.ago, reminder_frequency_days: 3)
  end
  let!(:signer) do
    agreement.agreement_signers.create!(name: 'Matt Buyer', email: 'matt@example.com', phone: '3035550100',
                                        role: 'signer', signing_order: 1)
  end

  before do
    allow(PortalPushService).to receive(:document_to_sign)
    allow(PortalPushService).to receive(:document_signature_reminder)
    allow(CommunicationService).to receive(:send_email).and_return({ success: true })
    allow(CommunicationService).to receive(:send_sms).and_return({ success: true })
    allow(WebhookService).to receive(:fire)
  end

  def reminder_webhooks
    RSpec::Mocks.space.proxy_for(WebhookService).messages_arg_list
                .select { |args| args.first[:event] == 'agreement.reminder_sent' }
  end

  it 'really sends the reminder by email and text, with the dealer name and the signer link' do
    described_class.check_and_send_reminders

    expect(CommunicationService).to have_received(:send_email).with(hash_including(
      to: 'matt@example.com',
      subject: "Reminder from #{company.name}: \"Purchase Agreement\" is still waiting for your signature",
      body: a_string_including(signer.signing_url),
      skip_preference_check: true,
      metadata: hash_including(type: 'signing_reminder', signer_id: signer.id)
    ))
    expect(CommunicationService).to have_received(:send_sms).with(hash_including(
      to: '3035550100',
      body: a_string_including(company.name, 'still waiting for your signature', signer.signing_url)
    ))

    reminder = agreement.agreement_reminders.sole
    expect(reminder).to have_attributes(reminder_type: 'auto', status: 'sent', agreement_signer_id: signer.id)
    expect(reminder.sent_at).to be_present
    expect(agreement.reload.last_reminder_sent_at).to be_present
    expect(reminder_webhooks.size).to eq(1)
    expect(agreement.agreement_audit_logs.where(action: AgreementAuditLog::ACTION_REMINDER_SENT)).to exist
  end

  it 'marks the reminder failed and fires no webhook when nothing went out' do
    allow(CommunicationService).to receive(:send_email).and_return({ success: false, error: 'SES down' })
    allow(CommunicationService).to receive(:send_sms).and_return({ success: false, error: 'Twilio down' })

    described_class.check_and_send_reminders

    reminder = agreement.agreement_reminders.sole
    expect(reminder.status).to eq('failed')
    expect(reminder.error_message).to be_present
    expect(reminder.sent_at).to be_nil
    expect(reminder_webhooks).to be_empty
    expect(agreement.agreement_audit_logs.where(action: AgreementAuditLog::ACTION_REMINDER_SENT)).not_to exist
  end

  it 'respects a blocked email address the way the first invite does' do
    agreement.update_columns(delivery_method: 'email')
    allow(CommunicationService).to receive(:send_email)
      .and_raise(CommunicationService::SuppressedRecipientError, 'matt@example.com cannot be emailed')

    described_class.check_and_send_reminders

    expect(CommunicationService).not_to have_received(:send_sms)
    expect(agreement.agreement_reminders.sole).to have_attributes(status: 'failed', error_message: 'matt@example.com cannot be emailed')
    expect(reminder_webhooks).to be_empty
  end

  it 'skips signers who already signed' do
    signer.update_columns(status: AgreementSigner::STATUS_SIGNED, signed_at: 1.hour.ago)

    described_class.check_and_send_reminders

    expect(CommunicationService).not_to have_received(:send_email)
    expect(agreement.agreement_reminders).to be_empty
  end

  it 'leaves agreements sent more than 30 days ago alone' do
    agreement.update_columns(sent_at: (described_class::AUTO_REMINDER_WINDOW + 1.day).ago)

    described_class.check_and_send_reminders

    expect(CommunicationService).not_to have_received(:send_email)
    expect(agreement.agreement_reminders).to be_empty
  end

  it 'stops at the expiry date' do
    agreement.update_columns(expires_at: 1.hour.ago)

    described_class.check_and_send_reminders

    expect(agreement.agreement_reminders).to be_empty
  end

  it 'waits for the reminder frequency' do
    agreement.update_columns(sent_at: 1.day.ago)

    described_class.check_and_send_reminders

    expect(agreement.agreement_reminders).to be_empty
  end

  it 'sends at most 3 automatic reminders to a signer' do
    expect(described_class::MAX_AUTO_REMINDERS_PER_SIGNER).to eq(3)
    start = agreement.sent_at

    5.times do |i|
      described_class.check_and_send_reminders(now: start + ((i + 1) * 3).days + 1.hour)
    end

    expect(agreement.agreement_reminders.where(reminder_type: 'auto').count).to eq(3)
    expect(CommunicationService).to have_received(:send_email).exactly(3).times
  end

  it 'still lets the Remind button send after the automatic ones are used up and the window has passed' do
    agreement.update_columns(sent_at: 60.days.ago)
    3.times do
      agreement.agreement_reminders.create!(agreement_signer: signer, scheduled_at: 50.days.ago,
                                            reminder_type: 'auto', channel: 'email', status: 'sent')
    end

    reminder = described_class.send_reminder(agreement, signer, 'manual')

    expect(reminder.status).to eq('sent')
    expect(CommunicationService).to have_received(:send_email).once
  end
end

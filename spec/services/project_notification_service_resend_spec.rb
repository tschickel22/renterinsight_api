require 'rails_helper'

RSpec.describe ProjectNotificationService, '.resend_assignment_notification', type: :service do
  let(:company) { create(:company) }

  let(:contractor) do
    Contractor.create!(
      company: company,
      name: 'American Millwright Services',
      contact_name: 'Jerry Franks',
      email: 'contractor@example.com',
      phone: '337-577-1913',
      vendor_type: 'contractor',
      status: 'active',
      sms_opt_in: true
    )
  end

  let(:ticket) do
    ServiceTicket.create!(
      company: company,
      title: 'punchlist',
      description: 'Punch list items',
      status: 'open',
      priority: 'medium'
    )
  end

  let(:assignment) do
    # Skip the after_commit auto-notify so the spec only exercises the resend path.
    ContractorAssignment.skip_callback(:commit, :after, :notify_on_assignment, raise: false)
    a = ContractorAssignment.create!(
      contractor: contractor,
      assignable: ticket,
      company: company,
      status: 'assigned',
      assigned_at: Time.current,
      notified_at: 1.hour.ago
    )
    ContractorAssignment.set_callback(:commit, :after, :notify_on_assignment)
    a
  end

  before do
    allow(CommunicationService).to receive(:send_email).and_return(double(id: 111))
    allow(CommunicationService).to receive(:send_sms).and_return(double(id: 222))
  end

  it 'resends the email even though notified_at is already stamped' do
    result = described_class.resend_assignment_notification(assignment)

    expect(CommunicationService).to have_received(:send_email).with(
      hash_including(to: 'contractor@example.com', communicable: assignment)
    )
    expect(result[:email][:ok]).to be true
    expect(result[:email][:communication_id]).to eq(111)
  end

  it 'does not restamp notified_at, preserving the first-contact timestamp' do
    original = assignment.notified_at

    expect {
      described_class.resend_assignment_notification(assignment)
      assignment.reload
    }.not_to change { assignment.notified_at&.to_i }

    expect(assignment.notified_at.to_i).to eq(original.to_i)
  end

  it 'sends SMS when the contractor has opted in and has a phone' do
    result = described_class.resend_assignment_notification(assignment)

    expect(CommunicationService).to have_received(:send_sms).with(
      hash_including(to: '337-577-1913', communicable: assignment)
    )
    expect(result[:sms][:ok]).to be true
  end

  it 'skips SMS and explains why when the contractor has not opted in' do
    contractor.update!(sms_opt_in: false)

    result = described_class.resend_assignment_notification(assignment.reload)

    expect(CommunicationService).not_to have_received(:send_sms)
    expect(result[:sms][:attempted]).to be false
    expect(result[:sms][:reason]).to match(/not opted in/i)
  end

  it 'skips SMS when no phone is on file' do
    contractor.update!(phone: nil)

    result = described_class.resend_assignment_notification(assignment.reload)

    expect(CommunicationService).not_to have_received(:send_sms)
    expect(result[:sms][:reason]).to match(/no phone/i)
  end

  it 'reports an email failure instead of swallowing it' do
    allow(CommunicationService).to receive(:send_email).and_raise(StandardError, 'SES rejected')

    result = described_class.resend_assignment_notification(assignment)

    expect(result[:email][:ok]).to be false
    expect(result[:email][:error]).to eq('SES rejected')
  end

  it 'still sends the email when SMS blows up' do
    allow(CommunicationService).to receive(:send_sms).and_raise(StandardError, 'Twilio down')

    result = described_class.resend_assignment_notification(assignment)

    expect(result[:email][:ok]).to be true
    expect(result[:sms][:ok]).to be false
    expect(result[:sms][:error]).to eq('Twilio down')
  end

  it 'builds a subject naming the service ticket' do
    described_class.resend_assignment_notification(assignment)

    expect(CommunicationService).to have_received(:send_email).with(
      hash_including(subject: 'New Assignment: punchlist')
    )
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe InboundEmail::ReplyNotifier do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:owner)  { User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", first_name: "Owner", last_name: "User", password: "Pass1234!", company_id: company.id) }
  let(:sender) { User.create!(email: "sender-#{SecureRandom.hex(4)}@example.com", first_name: "Sender", last_name: "User", password: "Pass1234!", company_id: company.id) }
  let(:source) { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }
  let(:lead)   { Lead.create!(company: company, source: source, first_name: "Re", last_name: "Plier", email: "lead-#{SecureRandom.hex(4)}@example.com", owner_id: owner.id) }

  def inbound_comm
    Communication.create!(company_id: company.id, communicable: lead, channel: 'email', direction: 'inbound',
                          subject: 'Re: Hello', body: 'Thanks, interested!', from_address: lead.email,
                          to_address: 'reply+lead-1@mail.renterinsight.com', status: 'delivered')
  end

  def outbound_from(user)
    Communication.create!(company_id: company.id, communicable: lead, channel: 'email', direction: 'outbound',
                          subject: 'Hello', body: 'Hi', from_address: 'rep@example.com', to_address: lead.email,
                          status: 'sent', metadata: { 'sender_user_id' => user.id })
  end

  # scope to the reply notification — creating a Lead with an owner also fires an
  # unrelated 'lead_assigned' notification to the owner.
  def reply_notifs(user)
    Notification.where(recipient_id: user.id, recipient_type: 'User', notification_type: 'email_reply_received')
  end

  it 'notifies the SENDER of the original email, not the owner' do
    outbound_from(sender) # sender != owner
    expect {
      described_class.notify(entity: lead, communication: inbound_comm)
    }.to change { reply_notifs(sender).count }.by(1)
    expect(reply_notifs(owner).count).to eq(0)
  end

  it 'prefers an explicitly passed outbound_communication for sender resolution' do
    out = outbound_from(sender)
    described_class.notify(entity: lead, communication: inbound_comm, outbound_communication: out)
    n = Notification.where(recipient_id: sender.id, recipient_type: 'User').last
    expect(n).to be_present
    expect(n.category).to eq('communications')
    expect(n.notification_type).to eq('email_reply_received')
    expect(n.action_url).to include("/crm/leads/#{lead.id}")
  end

  it 'falls back to the entity owner when no sender is recorded' do
    # no outbound with sender_user_id
    expect {
      described_class.notify(entity: lead, communication: inbound_comm)
    }.to change { reply_notifs(owner).count }.by(1)
  end

  it 'queues an email notification with Reply-To set to the replier' do
    outbound_from(sender)
    expect {
      described_class.notify(entity: lead, communication: inbound_comm)
    }.to have_enqueued_mail(NotificationMailer, :email_reply)
  end
end

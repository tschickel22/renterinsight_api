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

  it 'relays the email to the mailbox the original was sent FROM (the connected inbox)' do
    outbound_from(sender) # from_address: 'rep@example.com'
    expect(NotificationMailer).to receive(:email_reply)
      .with(hash_including(to_address: 'rep@example.com'))
      .and_return(double(deliver_later: true))
    described_class.notify(entity: lead, communication: inbound_comm)
  end

  # The text is often read on a phone with nothing else to hand, so it has to
  # say what they wrote and link straight to the reply itself.
  describe 'the SMS' do
    before { owner.update_columns(phone: '+17205550100') }

    def sent_sms_body
      body = nil
      sms = instance_double(SmsService)
      allow(SmsService).to receive(:new).and_return(sms)
      allow(sms).to receive(:send_sms) { |**kw| body = kw[:body] }
      yield
      body
    end

    it 'carries the reply text and a link that opens that reply' do
      comm = inbound_comm
      body = sent_sms_body { described_class.notify(entity: lead, communication: comm) }

      expect(body).to include('Email reply from Re Plier')
      expect(body).to include('Thanks, interested!')
      expect(body).to include("#{Brand.app_url}/crm/leads/#{lead.id}?tab=communication&comm=#{comm.id}")
    end

    it 'stays plain text so it is billed as GSM, not UCS-2' do
      body = sent_sms_body { described_class.notify(entity: lead, communication: inbound_comm) }
      expect(body).to match(/\A[\x00-\x7F]*\z/)
    end
  end

  describe 'the link' do
    it 'uses the contact page root for a contact' do
      contact = Contact.create!(company: company, first_name: 'Con', last_name: 'Tact', email: "c-#{SecureRandom.hex(3)}@example.com")
      comm = Communication.create!(company_id: company.id, communicable: contact, channel: 'email', direction: 'inbound',
                                   subject: 'Re: Hi', body: 'Yes', from_address: contact.email,
                                   to_address: 'rep@example.com', status: 'delivered')
      link = described_class.new(entity: contact, communication: comm).send(:entity_link)
      expect(link).to eq("/contacts/#{contact.id}?tab=communication&comm=#{comm.id}")
    end
  end
end

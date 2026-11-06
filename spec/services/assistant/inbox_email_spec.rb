# frozen_string_literal: true

require 'rails_helper'

# Email replies land in the Inbox (E96), so a dealer with no texting number
# still has one, and a person's email answer counts as answering.
RSpec.describe 'Inbox email conversations' do
  let(:company) { Company.create!(name: "Co #{SecureRandom.hex(3)}") }
  let(:rep) do
    User.create!(email: "r-#{SecureRandom.hex(3)}@ex.com", first_name: 'Jordan', last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let(:lead) { company.leads.create!(first_name: 'Tia', last_name: 'May', email: 'tia@example.com', owner_id: rep.id) }

  def email(direction, body:, **meta)
    Communication.create!(company_id: company.id, communicable: lead, channel: 'email', direction: direction,
                          status: 'delivered', from_address: 'tia@example.com', to_address: 'reply+lead@x.test',
                          subject: 'Re: The Hawthorne', body: body, metadata: meta)
  end

  it 'opens a conversation for a tracked reply, newest message first in the row' do
    comm = email('inbound', body: 'Is it still available?', reply_tracking_token: "lead-#{lead.id}")
    conversation = Conversation.find_by(conversable: lead)
    expect(conversation).to have_attributes(channel: 'email', status: 'active', assistant_enabled: false, assigned_user_id: rep.id,
                                            last_message_preview: 'Is it still available?')
    expect(comm.reload.conversation_id).to eq(conversation.id)
    expect(conversation.last_inbound_at).to be_present
  end

  it 'counts a person answering by email, and ignores automated mail and auto-replies' do
    email('inbound', body: 'Hi', reply_tracking_token: "lead-#{lead.id}")
    conversation = Conversation.find_by(conversable: lead)

    email('outbound', body: '<p>Weekly homes</p>', campaign_send_id: 9)
    expect(conversation.reload.last_person_reply_at).to be_nil

    email('outbound', body: '<p>Yes it is, <b>come by Saturday</b></p>', sender_user_id: rep.id)
    expect(conversation.reload.last_person_reply_at).to be_present
    expect(conversation.last_message_preview).to eq('Yes it is, come by Saturday')

    expect { email('inbound', body: 'Out of office', campaign_send_id: 9, is_ooo: true) }.not_to(change { conversation.reload.last_inbound_at })
  end

  it 'puts an email reply in the same row as their texts, and takes it from the assistant' do
    conversation = Conversation.create!(company: company, conversable: lead, sender_number: '+17205550100', buyer_phone: '+13035550144',
                                        status: 'active', assistant_enabled: true, started_at: Time.current)
    email('inbound', body: 'Sending my questions by email', reply_tracking_token: "lead-#{lead.id}")
    expect(Conversation.where(conversable: lead).count).to eq(1)
    expect(conversation.reload).to have_attributes(status: 'handed_off', handoff_reason: 'email_reply')
  end

  it 'leaves an email that answers nothing out of the Inbox' do
    email('inbound', body: 'BCC copy')
    expect(Conversation.where(conversable: lead)).to be_empty
  end
end

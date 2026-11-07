# frozen_string_literal: true

require 'rails_helper'

# Open Inboxes hear that a conversation changed (E96), for their own company only.
RSpec.describe InboxChannel, type: :channel do
  let(:company) { Company.create!(name: "Co #{SecureRandom.hex(3)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'Ada', last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'sales_rep', status: 'active')
  end

  it 'streams the person\'s own company' do
    stub_connection current_user: user
    subscribe
    expect(subscription).to have_stream_from("inbox_company_#{company.id}")
  end

  it 'announces a new message' do
    lead = company.leads.create!(first_name: 'Tia', phone: '3035550144')
    conversation = company.conversations.create!(conversable: lead, channel: 'sms', status: 'active', buyer_phone: '3035550144', sender_number: '7205550100')
    comm = Communication.create!(communicable: lead, company_id: company.id, channel: 'sms', direction: 'inbound', status: 'delivered',
                                 body: 'Hi', to_address: '+17205550100', from_address: '+13035550144')
    expect { conversation.note_message!(comm) }
      .to have_broadcasted_to("inbox_company_#{company.id}").with(conversation_id: conversation.id)
  end
end

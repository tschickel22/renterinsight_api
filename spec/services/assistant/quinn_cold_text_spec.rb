# frozen_string_literal: true

require 'rails_helper'

# Quinn AI answers texts to the dealer's number that answer nothing we sent
# (E96, Tom 2026-11-09), by the dealer's "When someone texts your number
# first" choice.
RSpec.describe 'Quinn AI answers texts from new people' do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Cold #{SecureRandom.hex(3)} Homes", industry: 'manufactured_housing') }
  let!(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Jordan', last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let!(:account) do
    TwilioAccount.create!(company: company, phone_number: '+17205550100', phone_number_sid: "PN#{SecureRandom.hex(8)}", status: 'active')
  end

  before do
    TenantModuleOverride.create!(company: company, module_key: 'marketing.lead_assistant', is_enabled: true)
    Assistant::Settings.for(company).update!('enabled' => true)
  end

  # What Webhooks::TwilioController#sms_inbound does with a cold text.
  def text_in(from, body)
    cold = ColdTextHandler.new(company: company, twilio_account: account, from: from, to: '+17205550100',
                               body: body, message_sid: "SM#{SecureRandom.hex(8)}").call
    conversation = Assistant::Threading.track_inbound!(company: company, record: cold.record, communication: cold.communication,
                                                       our_number: '+17205550100', buyer_number: from)
    [cold, conversation, Assistant::ColdText.consider(conversation, cold)]
  end

  it 'takes a text from someone new: a lead that may get replies about it, and Quinn answering' do
    cold, conversation, taken = text_in('+13035550177', 'Do you have any 3 bedroom homes?')
    expect(taken).to be(true)
    expect(cold.created_lead).to be(true)
    expect(conversation.reload).to have_attributes(assistant_enabled: true, status: 'active')
    expect(cold.record.reload.sms_inquiry_consent).to be(true)
    expect(cold.record.may_text_about_inquiry).to be_truthy
    expect(conversation.reply_due_at).to be_present
    expect(AssistantReplyJob).to have_been_enqueued
  end

  it 'leaves leads already in the CRM to the team unless the dealer chose leads too' do
    lead = company.leads.create!(first_name: 'Ava', last_name: 'Stone', phone: '3035550188', status: 'contacted')
    _, conversation, taken = text_in('+13035550188', 'Hi, still looking')
    expect(taken).to be(false)
    expect(conversation.reload.assistant_enabled).to be(false)

    conversation.update!(status: 'closed')
    Assistant::Settings.for(company).update!('cold_texts' => 'leads')
    _, again, taken = text_in('+13035550188', 'Hello?')
    expect(taken).to be(true)
    expect(again.conversable).to eq(lead)
  end

  it 'never takes a customer, a closed lead, or anything when the dealer chose their team' do
    company.leads.create!(first_name: 'Lost', last_name: 'Lead', phone: '3035550199', status: 'lost')
    Assistant::Settings.for(company).update!('cold_texts' => 'leads')
    _, _, taken = text_in('+13035550199', 'hi')
    expect(taken).to be(false)

    Assistant::Settings.for(company).update!('cold_texts' => 'off')
    _, conversation, taken = text_in('+13035550166', 'Are you open Sunday?')
    expect(taken).to be(false)
    expect(conversation.reload.assistant_enabled).to be(false)
  end

  it 'does nothing without Quinn by text' do
    Assistant::Settings.for(company).update!('enabled' => false)
    _, _, taken = text_in('+13035550155', 'Price on the Hawthorne?')
    expect(taken).to be(false)
  end
end

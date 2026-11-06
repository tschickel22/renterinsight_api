# frozen_string_literal: true

require 'rails_helper'

# Lead Assistant (backlog E96): a play's first text opens a conversation, the
# buyer's reply is answered by the assistant, and a person can take it over.
RSpec.describe 'Lead Assistant', type: :request do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)} Homes", industry: 'manufactured_housing') }
  let!(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Jordan', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
  end
  let(:source) { Source.create!(name: 'Website', source_type: 'website', is_active: true) }
  let(:lead) do
    company.leads.create!(first_name: 'Tia', last_name: 'May', phone: '(303) 555-0144', email: 'tia@example.com',
                          owner_id: rep.id, source_id: source.id, opt_in_sms: true)
  end
  let(:own_number) { '+17205550100' }
  let(:sent) { [] }

  def turn_on!(**attrs)
    TenantModuleOverride.create!(company: company, module_key: 'marketing.lead_assistant', is_enabled: true)
    Assistant::Settings.for(company).update!({ 'enabled' => true }.merge(attrs.stringify_keys))
  end

  def own_account!
    TwilioAccount.create!(company: company, phone_number: own_number, phone_number_sid: "PN#{SecureRandom.hex(8)}", status: 'active')
  end

  def brain_says(reply:, handoff: false, reason: nil, qualification: {})
    allow_any_instance_of(Assistant::Brain).to receive(:call).and_return(
      Assistant::Brain::Result.new(reply: reply, qualification: qualification, handoff: handoff,
                                   handoff_reason: reason, summary: 'Wants a 3 bed on her land.', usage: {})
    )
  end

  def buyer_texts(body, to: own_number, from: '+13035550144')
    post '/webhooks/twilio/sms/inbound', params: { From: from, To: to, Body: body, MessageSid: "SM#{SecureRandom.hex(8)}" }
    expect(response).to have_http_status(:ok)
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TWILIO_AUTH_TOKEN').and_return(nil)
    allow(ENV).to receive(:[]).with('TWILIO_PHONE_NUMBER').and_return(nil)
    calls = sent
    allow_any_instance_of(Providers::Sms::TwilioProvider).to receive(:send_message) do |_provider, **args|
      calls << args
      { success: true, external_id: "SM#{SecureRandom.hex(8)}", provider: 'twilio' }
    end
  end

  describe 'opening a conversation' do
    it 'sends the play text from the dealer number, naming the dealer, and opens a conversation' do
      own_account!
      turn_on!
      starter = Assistant::Starter.for(lead)
      expect(starter.takes_over?).to be(true)

      starter.send_first_text!(body: 'Hi Tia, thanks for asking about the Hawthorne!')

      conversation = Conversation.last
      expect(conversation).to have_attributes(company_id: company.id, conversable: lead, sender_number: own_number,
                                              buyer_phone: '+13035550144', pool: false, status: 'active')
      expect(sent.last[:body]).to start_with("#{company.name}: Hi Tia")
      expect(sent.last[:from]).to eq(own_number)
      expect(Communication.last.conversation_id).to eq(conversation.id)
    end

    it 'stays out of it when the dealer has not turned it on, the lead did not agree to texts, or a partner AI has the lead' do
      own_account!
      expect(Assistant::Starter.for(lead).takes_over?).to be(false)

      turn_on!
      lead.update!(opt_in_sms: false)
      expect(Assistant::Starter.for(lead).takes_over?).to be(false)

      lead.update!(opt_in_sms: true, source_id: Source.create!(name: 'Mobile Home Guys', source_type: 'partner', is_active: true).id)
      expect(Assistant::Starter.for(lead).takes_over?).to be(false)
    end

    it 'needs the add-on as well as the switch' do
      own_account!
      Assistant::Settings.for(company).update!('enabled' => true)
      expect(Assistant::Starter.for(lead).takes_over?).to be(false)
    end

    it 'uses a live pool number with the dealer and platform named on every text' do
      turn_on!
      Setting.set('Platform', 0, 'assistant_pool',
                  { 'live' => true, 'numbers' => [{ 'number' => '+19704632673', 'messaging_service_sid' => 'MGpool' }] })

      Assistant::Starter.for(lead).send_first_text!(body: 'Hi Tia, thanks for asking!')

      conversation = Conversation.last
      expect(conversation).to have_attributes(pool: true, sender_number: '+19704632673', messaging_service_sid: 'MGpool')
      expect(sent.last[:body]).to eq("#{company.name} via #{Brand.current.name}: Hi Tia, thanks for asking!")
      expect(sent.last[:pool_messaging_service_sid]).to eq('MGpool')
    end

    it 'does not use the pool until it is marked live' do
      turn_on!
      Setting.set('Platform', 0, 'assistant_pool', { 'live' => false, 'numbers' => [{ 'number' => '+19704632673' }] })
      expect(Assistant::Starter.for(lead).takes_over?).to be(false)
    end
  end

  describe 'answering the buyer' do
    let!(:conversation) do
      own_account!
      turn_on!
      Assistant::Starter.for(lead).send_first_text!(body: 'Hi Tia, thanks for asking!')
      Conversation.last
    end

    it 'answers a reply itself after a short wait, and the rep is not pinged' do
      brain_says(reply: 'Happy to help. Are you placing it on your own land?', qualification: { 'bedrooms' => '3 bedrooms' })

      expect { buyer_texts('Do you have 3 bed homes?') }.to have_enqueued_job(AssistantReplyJob)
      expect(Notification.where(notification_type: 'sms_reply_received')).to be_empty

      perform_enqueued_jobs
      expect(sent.last[:body]).to eq('Happy to help. Are you placing it on your own land?')
      expect(conversation.reload.qualification).to include('bedrooms' => '3 bedrooms')
      expect(lead.reload.preferred_bedrooms).to eq(3)
      expect(Communication.where(conversation_id: conversation.id).order(:id).last.metadata['sent_by']).to eq('assistant')
    end

    it 'routes a reply to a pool number by the conversation, since the number names no dealer' do
      Setting.set('Platform', 0, 'assistant_pool', { 'live' => true, 'numbers' => [{ 'number' => '+19704632673', 'messaging_service_sid' => 'MGpool' }] })
      other = company.leads.create!(first_name: 'Ray', last_name: 'B', phone: '3035550199', owner_id: rep.id, opt_in_sms: true, source_id: source.id)
      TwilioAccount.where(company: company).destroy_all
      Assistant::Starter.for(other).send_first_text!(body: 'Hi Ray!')
      pool_conversation = Conversation.find_by(conversable: other)

      brain_says(reply: 'Great question.')
      expect { buyer_texts('Hello?', to: '+19704632673', from: '+13035550199') }.to have_enqueued_job(AssistantReplyJob)
      inbound = Communication.where(direction: 'inbound').last
      expect(inbound).to have_attributes(company_id: company.id, communicable: other, conversation_id: pool_conversation.id)
    end

    it 'hands off when the buyer asks about payments, and tells the rep' do
      brain_says(reply: 'Our finance manager will go over that with you. I have asked Jordan to text you.',
                 handoff: true, reason: 'finance_or_credit')
      buyer_texts('What would my payment be?')
      perform_enqueued_jobs

      expect(conversation.reload).to have_attributes(status: 'handed_off', handed_off_to_user_id: rep.id,
                                                     handoff_reason: 'finance_or_credit')
      expect(Notification.where(notification_type: 'assistant_handoff', recipient_id: rep.id)).to exist
    end

    it 'never sends a payment figure or a link: it tries again, then hands off' do
      brain_says(reply: 'That home is about $899 a month with financing.')
      buyer_texts('How much a month?')
      perform_enqueued_jobs

      expect(sent.map { |s| s[:body] }).not_to include(a_string_including('$899'))
      expect(conversation.reload.status).to eq('handed_off')
      expect(sent.last[:body]).to eq('I have asked Jordan to text you directly.')
    end

    it 'gives one answer to several quick texts' do
      brain_says(reply: 'Sure thing.')
      buyer_texts('Hi')
      buyer_texts('Are you open Sunday?')
      before = sent.size
      perform_enqueued_jobs
      expect(sent.size - before).to eq(1)
    end

    it 'steps back when a rep texts in the conversation, and the rep hears the next reply' do
      Assistant::Messenger.deliver!(conversation, body: 'Hi Tia, Jordan here.', sent_by: 'user', user: rep)
      expect(conversation.reload).to have_attributes(status: 'handed_off', handed_off_to_user_id: rep.id, handoff_reason: 'rep_replied')

      expect { buyer_texts('Hi Jordan') }.not_to have_enqueued_job(AssistantReplyJob)
      expect(Notification.where(notification_type: 'sms_reply_received', recipient_id: rep.id)).to exist
    end

    it 'closes the conversation on STOP' do
      buyer_texts('STOP')
      expect(conversation.reload.status).to eq('closed')
      expect(enqueued_jobs.select { |j| j['job_class'] == 'AssistantReplyJob' }).to be_empty
    end
  end

  describe Assistant::Rules do
    it 'refuses links and payment figures, and allows ordinary prices' do
      expect(described_class.violation('See www.summitpark.com')).to eq('link')
      expect(described_class.violation('Check https://x.co')).to eq('link')
      expect(described_class.violation('About $899 a month')).to eq('finance_figure')
      expect(described_class.violation('Rates start at 6.9% APR')).to eq('finance_figure')
      expect(described_class.violation('The Hawthorne is $89,900 delivered and set.')).to be_nil
      expect(described_class.tidy('Yes — we do')).to eq('Yes, we do')
    end
  end
end

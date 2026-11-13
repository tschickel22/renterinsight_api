# frozen_string_literal: true

require 'rails_helper'

# Quinn starts itself, works to the dealer's goal, answers the website chat
# into the Inbox, opens the chat after a form, and runs embedded on the
# dealer's own listed sites (E96, 2026-11-07).
RSpec.describe 'Quinn starts, goals and website chat', type: :request do
  include ActiveJob::TestHelper

  let(:company) { Company.create!(name: "Summit #{SecureRandom.hex(3)} Homes", industry: 'manufactured_housing') }
  let!(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Jordan', last_name: 'Rep',
                 password: 'Pass1234!', company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:headers) { { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: rep.id, company_id: company.id)}", 'Content-Type' => 'application/json' } }
  let(:own_number) { '+17205550100' }
  let(:sent) { [] }

  def texting_on!(**attrs)
    TenantModuleOverride.create!(company: company, module_key: 'marketing.lead_assistant', is_enabled: true)
    Assistant::Settings.for(company).update!({ 'enabled' => true }.merge(attrs.stringify_keys))
  end

  def chat_on!(**attrs)
    TenantModuleOverride.create!(company: company, module_key: 'marketing.ai_concierge', is_enabled: true)
    Assistant::Settings.for(company).update!(attrs.stringify_keys) if attrs.any?
  end

  def brain_says(reply:, handoff: false, reason: nil, contact: {}, qualification: {})
    allow_any_instance_of(Assistant::Brain).to receive(:call).and_return(
      Assistant::Brain::Result.new(reply: reply, qualification: qualification, contact: contact, resend_invite: false,
                                   photo_home_id: nil, question: nil, question_answered: false, question_topic: nil,
                                   handoff: handoff, handoff_reason: reason, summary: 'Wants a 3 bed.',
                                   usage: { input_tokens: 10, output_tokens: 5 })
    )
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

  describe 'Quinn texts a new lead itself' do
    before do
      TwilioAccount.create!(company: company, phone_number: own_number, phone_number_sid: "PN#{SecureRandom.hex(8)}", status: 'active')
      texting_on!
    end

    def new_lead(**attrs)
      company.leads.create!({ first_name: 'Tia', last_name: 'May', phone: '(303) 555-0144', email: 'tia@example.com',
                              owner_id: rep.id, sms_inquiry_consent: true, origin: Lead::ORIGIN_INTAKE_FORM }.merge(attrs))
    end

    it 'queues two minutes after a form lead arrives and sends Quinn\'s own first text with the opt out line' do
      brain_says(reply: 'Hi Tia, this is Quinn. Is the home going on your own land?')
      lead = nil
      expect { lead = new_lead }.to have_enqueued_job(AssistantStartJob)

      AssistantStartJob.perform_now(lead.id)
      expect(sent.size).to eq(1)
      expect(sent.last[:body]).to include('Hi Tia, this is Quinn').and end_with('Reply STOP to opt out.')
      expect(sent.last[:body]).to start_with(company.name)
      expect(Conversation.find_by(conversable: lead, channel: 'sms')).to be_present
    end

    it 'sends nothing for an import or a lead a rep typed in, or when a play already texted, or when switched off' do
      expect { new_lead(origin: nil) }.not_to have_enqueued_job(AssistantStartJob)

      brain_says(reply: 'Hi')
      lead = new_lead
      Communication.create!(communicable: lead, company_id: company.id, channel: 'sms', direction: 'outbound', status: 'sent',
                            body: 'Thanks from the play', to_address: '+13035550144', from_address: own_number)
      AssistantStartJob.perform_now(lead.id)
      expect(sent).to be_empty

      Assistant::Settings.for(company).update!('auto_start' => false)
      expect { new_lead(phone: '(303) 555-0199') }.not_to have_enqueued_job(AssistantStartJob)
    end

    it 'leaves the lead alone while they are talking in the website chat' do
      chat_on!
      brain_says(reply: 'Hi')
      lead = new_lead
      conversation = Assistant::WebChat.after_form!(lead: lead)
      conversation.chat_messages.create!(direction: 'inbound', sent_by: 'visitor', body: 'Do you deliver to Elbert County?')
      AssistantStartJob.perform_now(lead.id)
      expect(sent).to be_empty
    end
  end

  describe 'the goal' do
    let(:lead) { company.leads.create!(first_name: 'Tia', phone: '3035550144', sms_inquiry_consent: true) }
    let(:conversation) { company.conversations.create!(channel: 'sms', status: 'active', conversable: lead, buyer_phone: '3035550144', sender_number: own_number) }

    def prompt
      Assistant::Brain.new(conversation: conversation, settings: Assistant::Settings.for(company), history: []).system_prompt
    end

    it 'works toward a visit, or to a rep straight away while the dealer is open' do
      Assistant::Settings.for(company).update!('goal' => 'book_always')
      expect(prompt).to include('Your goal is a visit').and include('visit_time')

      Assistant::Settings.for(company).update!('goal' => 'book_after_hours')
      allow(Assistant::Hours).to receive(:open_now?).and_return(true)
      expect(prompt).to include('open right now').and include('ready_for_rep')
      allow(Assistant::Hours).to receive(:open_now?).and_return(false)
      expect(prompt).to include('Your goal is a visit')

      Assistant::Settings.for(company).update!('goal' => 'answer_only')
      expect(prompt).to include('Do not ask them qualifying questions')
    end

    it 'reads business hours in the location time zone' do
      location = company.locations.create!(name: 'Denver', timezone: 'America/Denver',
                                           business_hours: { 'monday' => { 'open' => '09:00', 'close' => '17:00', 'closed' => false } })
      monday_10am = Time.find_zone('America/Denver').local(2026, 11, 9, 10, 0)
      expect(Assistant::Hours.open_now?(company, location, at: monday_10am)).to be(true)
      expect(Assistant::Hours.open_now?(company, location, at: monday_10am + 8.hours)).to be(false)
      expect(Assistant::Hours.open_now?(company, location, at: monday_10am + 1.day)).to be(false)
    end
  end

  describe 'the website chat' do
    let(:token) { company.public_inventory_token }

    before { chat_on! }

    it 'answers as Quinn, keeps the chat in the Inbox, and makes the lead once it has a name and email' do
      brain_says(reply: 'Happy to help. What size home are you after?')
      post "/concierge/#{token}", params: { message: 'Hi, can you help me find a home?' }.to_json, headers: { 'Content-Type' => 'application/json' }
      body = JSON.parse(response.body)
      key = body['chat_key']
      expect(key).to be_present
      expect(body['messages'].map { |m| m['content'] }).to eq(['Happy to help. What size home are you after?'])
      expect(body['events']).to eq([])

      conversation = Conversation.find_by(visitor_token: key)
      expect(conversation).to have_attributes(channel: 'web_chat', status: 'active')
      expect(conversation.chat_messages.count).to eq(2)

      brain_says(reply: 'Thanks Tia, someone will be in touch.', contact: { 'first_name' => 'Tia', 'last_name' => 'May', 'email' => 'tia@example.com' })
      allow_any_instance_of(Concierge::LeadCapture).to receive(:available?).and_return(true)
      lead = company.leads.create!(first_name: 'Tia', last_name: 'May', email: 'tia@example.com')
      allow_any_instance_of(Concierge::LeadCapture).to receive(:call).and_return(Concierge::LeadCapture::Result.new(status: 'created', lead_id: lead.id))
      post "/concierge/#{token}", params: { message: 'Tia May, tia@example.com', chat_key: key }.to_json, headers: { 'Content-Type' => 'application/json' }
      expect(conversation.reload.conversable).to eq(lead)
      # The page's ad pixel counts it as a Lead, by an id that does not show the lead's.
      events = JSON.parse(response.body)['events']
      expect(events).to eq([{ 'name' => 'Lead', 'id' => Assistant::Conversions.lead(lead)[:id] }])
      expect(events.first['id']).to match(/\Adt-[a-f0-9]{24}\z/)

      # Once: the next message on the same lead counts nothing.
      brain_says(reply: 'Anything else?')
      post "/concierge/#{token}", params: { message: 'Thanks', chat_key: key }.to_json, headers: { 'Content-Type' => 'application/json' }
      expect(JSON.parse(response.body)['events']).to eq([])

      get '/api/crm/conversations', headers: headers
      row = JSON.parse(response.body)['items'].detect { |r| r['id'] == conversation.id }
      expect(row).to include('channel' => 'web_chat', 'state' => 'Assistant')
    end

    it 'answers a message that is a search and more, with the matching homes as cards under Quinn\'s reply' do
      company.vehicles.create!(vin: "VIN#{SecureRandom.hex(6)}", year: 2026, make: 'Champion', model: 'Shoal Creek', bedrooms: 3,
                               sale_price: 89_900, status: 'available')
      brain_says(reply: 'Thanks Testy, here are our 3 bedroom homes. Someone will email you details.')
      post "/concierge/#{token}", params: { message: '3 bedrooms. I am Testy, testy@example.com, send details?' }.to_json,
                                  headers: { 'Content-Type' => 'application/json' }
      message = JSON.parse(response.body)['messages'].last
      expect(message['content']).to start_with('Thanks Testy')
      expect(message['listings'].map { |l| l['name'] }).to include('2026 Champion Shoal Creek')
    end

    it 'holds a handoff until the visitor leaves a name and contact, then hands it to the lead\'s owner' do
      owner = User.create!(email: "owner-#{SecureRandom.hex(4)}@example.com", first_name: 'Casey', last_name: 'Owner',
                           password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
      brain_says(reply: 'Happy to set that up.', handoff: true, reason: 'appointment')
      post "/concierge/#{token}", params: { message: "I'd like to book a visit." }.to_json, headers: { 'Content-Type' => 'application/json' }
      body = JSON.parse(response.body)
      conversation = Conversation.find_by(visitor_token: body['chat_key'])
      # No way to reach them yet: Quinn keeps it and asks, nobody is told.
      expect(conversation).to have_attributes(status: 'active', handoff_reason: 'appointment', assigned_user_id: nil)
      expect(body['messages'].last['content']).to eq("Happy to set that up. #{Assistant::WebChat::ASK_CONTACT}")
      expect(Notification.where(notification_type: 'assistant_handoff')).not_to exist
      get '/api/crm/conversations', headers: headers
      row = JSON.parse(response.body)['items'].detect { |r| r['id'] == conversation.id }
      expect(row).to include('state' => 'Assistant', 'handoff_label' => nil)
      # The Quinn view lists it with why it is still with Quinn.
      get '/api/crm/conversations', params: { view: 'with_quinn' }, headers: headers
      quinn = JSON.parse(response.body)
      expect(quinn['meta']['counts']['with_quinn']).to eq(1)
      note = quinn['items'].first['quinn_note']
      expect(note).to include('held' => true, 'short' => 'Waiting for their name and contact')
      expect(note['detail']).to start_with('This visitor wants to set a time to visit. Quinn AI asked')

      # The lead the form makes belongs to the form's rotation pick, who gets it.
      lead = company.leads.create!(first_name: 'Tia', last_name: 'May', email: 'tia@example.com', owner_id: owner.id)
      allow_any_instance_of(Concierge::LeadCapture).to receive(:call).and_return(Concierge::LeadCapture::Result.new(status: 'created', lead_id: lead.id))
      brain_says(reply: 'Thanks Tia, the team will reach out about a time.',
                 contact: { 'first_name' => 'Tia', 'last_name' => 'May', 'email' => 'tia@example.com' })
      post "/concierge/#{token}", params: { message: 'Tia May, tia@example.com', chat_key: body['chat_key'] }.to_json,
                                  headers: { 'Content-Type' => 'application/json' }
      expect(conversation.reload).to have_attributes(status: 'handed_off', handoff_reason: 'appointment',
                                                     handed_off_to_user_id: owner.id, assigned_user_id: owner.id)
      expect(JSON.parse(response.body)['messages'].last['content']).to start_with('Thanks Tia')
      expect(Notification.where(notification_type: 'assistant_handoff', recipient: owner).count).to eq(1)
      expect(Notification.where(notification_type: 'assistant_handoff', recipient: rep)).not_to exist
      get '/api/crm/conversations', params: { view: 'with_quinn' }, headers: headers
      expect(JSON.parse(response.body)['items']).to eq([])
    end

    it 'hands a chat whose lead has no owner to the form\'s rotation, not the first admin' do
      picked = User.create!(email: "rot-#{SecureRandom.hex(4)}@example.com", first_name: 'Robin', last_name: 'Rota',
                            password: 'Pass1234!', company_id: company.id, role: 'sales_rep', status: 'active')
      list = RoundRobinAssignmentList.create!(company_id: company.id, name: 'Chat rotation', user_ids: [picked.id], active: true)
      form = company.intake_forms.create!(name: 'Website Contact', assignment_mode: 'round_robin', round_robin_list: list,
                                          notified_user_id: rep.id, auto_create_lead: true, is_active: true)
      allow_any_instance_of(Concierge::LeadCapture).to receive(:form).and_return(form)
      lead = company.leads.create!(first_name: 'Tia', email: 'tia@example.com')
      chat = Assistant::WebChat.after_form!(lead: lead)
      brain_says(reply: '', handoff: true, reason: 'asked_for_person')
      post "/concierge/#{token}", params: { message: 'Can I talk to a person?', chat_key: chat.visitor_token }.to_json,
                                  headers: { 'Content-Type' => 'application/json' }
      expect(chat.reload).to have_attributes(status: 'handed_off', handed_off_to_user_id: picked.id, assigned_user_id: picked.id)
      expect(Notification.where(notification_type: 'assistant_handoff', recipient: rep)).not_to exist
    end

    it 'hands a held chat off when a typed number makes the lead' do
      brain_says(reply: '', handoff: true, reason: 'asked_for_person')
      post "/concierge/#{token}", params: { message: 'Can I talk to a person?' }.to_json, headers: { 'Content-Type' => 'application/json' }
      key = JSON.parse(response.body)['chat_key']
      conversation = Conversation.find_by(visitor_token: key)
      expect(JSON.parse(response.body)['messages'].last['content']).to eq(Assistant::WebChat::ASK_CONTACT)
      expect(conversation.status).to eq('active')

      lead = company.leads.create!(first_name: 'Tia', phone: '(303) 555-0144', owner_id: rep.id)
      allow_any_instance_of(Concierge::LeadCapture).to receive(:call).and_return(Concierge::LeadCapture::Result.new(status: 'created', lead_id: lead.id))
      post "/concierge/#{token}/lead", params: { chat_key: key, consented: true, visitor: { name: 'Tia', phone: '(303) 555-0144' } }.to_json,
                                       headers: { 'Content-Type' => 'application/json' }
      expect(conversation.reload).to have_attributes(status: 'handed_off', handoff_reason: 'asked_for_person', handed_off_to_user_id: rep.id)
      expect(conversation.chat_messages.order(:id).last.body).to include('to join this chat')
    end

    it 'hands off into the chat, then the rep answers from the Inbox and the visitor gets it' do
      lead = company.leads.create!(first_name: 'Tia', email: 'tia@example.com', owner_id: rep.id)
      chat = Assistant::WebChat.after_form!(lead: lead)
      brain_says(reply: '', handoff: true, reason: 'asked_for_person')
      post "/concierge/#{token}", params: { message: 'Can I talk to a person?', chat_key: chat.visitor_token }.to_json,
                                  headers: { 'Content-Type' => 'application/json' }
      body = JSON.parse(response.body).merge('chat_key' => chat.visitor_token)
      conversation = chat.reload
      expect(conversation.status).to eq('handed_off')
      expect(body['messages'].last['content']).to include('to join this chat')
      expect(Notification.where(notification_type: 'assistant_handoff', recipient: rep)).to exist

      # Quinn stays quiet once a person has it.
      post "/concierge/#{token}", params: { message: 'Hello?', chat_key: body['chat_key'] }.to_json, headers: { 'Content-Type' => 'application/json' }
      expect(JSON.parse(response.body)['messages']).to eq([])

      last_id = conversation.chat_messages.maximum(:id)
      post "/api/crm/conversations/#{conversation.id}/chat_reply", params: { body: 'Hi, this is Jordan.' }.to_json, headers: headers
      expect(response).to have_http_status(:ok)

      get "/concierge/#{token}/chat", params: { chat_key: body['chat_key'], after: last_id }
      polled = JSON.parse(response.body)
      expect(polled['messages'].map { |m| m['content'] }).to eq(['Hi, this is Jordan.'])
      expect(polled['messages'].first['from_person']).to be(true)
      expect(conversation.reload.visitor_on_page?).to be(true)

      get "/api/crm/conversations/#{conversation.id}/chat_messages", headers: headers
      # Quinn's greeting after the form, the question, the handoff line, the rep.
      expect(JSON.parse(response.body)['messages'].size).to eq(5)
    end

    it 'puts the number and the yes to texts on the chat\'s lead' do
      lead = company.leads.create!(first_name: 'Tia', email: 'tia@example.com')
      conversation = Assistant::WebChat.after_form!(lead: lead)
      post "/concierge/#{token}/lead", params: { chat_key: conversation.visitor_token, consented: true,
                                                 visitor: { name: 'Tia', phone: '(303) 555-0144' } }.to_json,
                                       headers: { 'Content-Type' => 'application/json' }
      expect(lead.reload.sms_inquiry_consent).to be(true)
      expect(lead.phone.gsub(/\D/, '')).to eq('3035550144')
      # Already counted when the form made the lead.
      expect(JSON.parse(response.body)).not_to have_key('events')
    end

    it 'runs embedded only on the sites the dealer listed' do
      brain_says(reply: 'Hi there')
      post "/concierge/#{token}", params: { message: 'hi', site: 'stranger.example.com' }.to_json, headers: { 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:forbidden)

      Assistant::Settings.for(company).update!('chat_sites' => ['https://www.summitparkhomes.com/'])
      post "/concierge/#{token}", params: { message: 'hi', site: 'summitparkhomes.com' }.to_json, headers: { 'Content-Type' => 'application/json' }
      expect(response).to have_http_status(:ok)
      get "/concierge/#{token}/config", params: { site: 'www.summitparkhomes.com' }
      expect(JSON.parse(response.body)['assistant_name']).to eq('Quinn')

      get "/chat/#{token}.js", headers: { 'Referer' => 'https://summitparkhomes.com/homes' }
      expect(response.body).to include('/chat-embed/').and include(token)
      # Fires the chat's lead on the dealer's own pixel, after any cookie consent.
      expect(response.body).to include("d.type === 'dealertide-chat-event'").and include("window.fbq('track', ev.name")
                                                                               .and include('siteConsent.onGrant(fire)')
      get "/chat/#{token}.js", headers: { 'Referer' => 'https://stranger.example.com/' }
      expect(response.body).to include('not listed')
    end

    it 'greets a software company as a product chat and offers Contact us and Set a demo' do
      Assistant::Settings.for(company).update!('chat_sites' => ['summitparkhomes.com'], 'visit_minutes' => 30)
      get "/concierge/#{token}/config", params: { site: 'summitparkhomes.com' }
      dealer = JSON.parse(response.body)
      expect(dealer['greeting']).to include('our homes, financing or a visit')
      expect(dealer['greeting']).not_to include('price')
      expect(dealer['placeholder']).to include('homes')
      expect(dealer['quick_actions']).to include(hash_including('type' => 'ask', 'label' => 'Book a visit'))

      company.update!(industry: 'saas')
      get "/concierge/#{token}/config", params: { site: 'summitparkhomes.com' }
      body = JSON.parse(response.body)
      expect(body['greeting']).to include('help your dealership').and include('30 minute demo')
      expect(body['greeting']).not_to include('homes')
      expect(body['placeholder']).to eq('Ask about our products or a demo…')
      expect(body['quick_actions'].map { |a| a['label'] }).to eq(['Contact us', 'Set a demo'])
      expect(body['quick_actions'].last).to include('type' => 'ask', 'message' => "I'd like to set up a demo.")
    end

    it 'opens the chat on the new lead when a form is sent' do
      form = IntakeForm.create!(company: company, name: 'Contact', public_id: "f#{SecureRandom.hex(4)}", is_active: true, auto_create_lead: true,
                                fields: [{ 'name' => 'first_name', 'label' => 'First name' }, { 'name' => 'email', 'label' => 'Email' }])
      post "/f/#{form.public_id}/submit", params: { first_name: 'Tia', email: 'tia@example.com' }.to_json,
                                          headers: { 'Content-Type' => 'application/json' }
      body = JSON.parse(response.body)
      expect(body['success']).to be(true), body.inspect
      conversation = Conversation.find_by(visitor_token: body.dig('chat', 'key'))
      expect(conversation).to be_present, body.inspect
      expect(conversation.conversable).to be_a(Lead)
      expect(conversation.chat_messages.first.body).to start_with('Thanks, Tia!')
    end
  end

  it 'saves the goal, the start switch and the chat sites, and gives the embed line' do
    chat_on!
    put '/api/crm/lead_assistant_settings', headers: headers,
                                            params: { settings: { goal: 'book_after_hours', auto_start: false, chat_sites: ['www.Summit.com', 'bad url %%'] } }.to_json
    body = JSON.parse(response.body)
    expect(body['settings']).to include('goal' => 'book_after_hours', 'auto_start' => false, 'chat_sites' => ['summit.com'])
    expect(body['chat']['embed_code']).to include("/chat/#{company.public_inventory_token}.js")
  end
end

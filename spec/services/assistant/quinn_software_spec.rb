# frozen_string_literal: true

require 'rails_helper'

# Quinn on a software company's own website (DealerTide, industry saas):
# answers from the product list, help articles and shared training videos,
# never quotes a price, shows a Watch button for a video that shows the
# answer, and books a demo by video call with the chosen person.
RSpec.describe 'Quinn for a software company', type: :request do
  let(:company) { Company.create!(name: "DealerTide #{SecureRandom.hex(3)}", industry: 'saas') }
  let!(:location) do
    company.locations.create!(name: 'HQ', timezone: 'America/Denver', address_line1: '1 Main St', city: 'Denver', state: 'CO',
                              business_hours: Assistant::Hours::DAYS.index_with { |d| { 'open' => '09:00', 'close' => '17:00', 'closed' => d == 'sunday' } })
  end
  let!(:tom) do
    User.create!(email: "tom-#{SecureRandom.hex(4)}@example.com", first_name: 'Tom', last_name: 'Owner', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active', meeting_url: 'https://zoom.us/j/123456')
  end
  let!(:rep) do
    User.create!(email: "rep-#{SecureRandom.hex(4)}@example.com", first_name: 'Jordan', last_name: 'Rep', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:lead) do
    company.leads.create!(first_name: 'Tia', last_name: 'May', email: 'tia@example.com', owner_id: rep.id, location_id: location.id)
  end
  let(:conversation) do
    company.conversations.create!(channel: 'web_chat', status: 'active', assistant_enabled: true, conversable: lead,
                                  visitor_token: SecureRandom.urlsafe_base64(24), location_id: location.id, started_at: Time.current)
  end
  let!(:article) do
    Knowledge::Article.create!(title: 'Send a text campaign', slug: "text-campaign-#{SecureRandom.hex(3)}", article_type: 'how_to',
                               is_published: true, excerpt: 'Campaigns text your leads in bulk.',
                               content: 'Open Marketing, Campaigns, pick Text, choose an audience and send.')
  end
  let!(:shared_video) do
    TrainingVideo.create!(title: 'Text campaigns', video_url: 'https://cdn.example.com/a.mp4', is_published: true, share_enabled: true,
                          description: 'How to send a text campaign to your leads.')
  end
  let!(:private_video) do
    TrainingVideo.create!(title: 'Text campaigns in depth', video_url: 'https://cdn.example.com/b.mp4', is_published: true,
                          share_enabled: false, description: 'Text campaign settings.')
  end

  before do
    TenantModuleOverride.create!(company: company, module_key: 'marketing.ai_concierge', is_enabled: true)
    Assistant::Settings.for(company).update!('book_with_user_id' => tom.id, 'visit_minutes' => 30, 'goal' => 'book_always')
  end

  def visitor(text)
    conversation.chat_messages.create!(company_id: company.id, direction: 'inbound', sent_by: 'visitor', body: text)
  end

  def brain_says(reply, **extra)
    allow_any_instance_of(Assistant::Brain).to receive(:call).and_return(
      Assistant::Brain::Result.new({ reply: reply, qualification: {}, contact: {}, resend_invite: false, photo_home_id: nil,
                                     question: nil, question_answered: false, question_topic: nil, handoff: false,
                                     handoff_reason: nil, summary: '', usage: {} }.merge(extra))
    )
  end

  it 'answers from the product, help articles and shared videos, with no homes and no prices' do
    visitor('How do text campaigns work?')
    brain = Assistant::Brain.new(conversation: conversation, settings: Assistant::Settings.for(company),
                                 history: conversation.history(Assistant::Brain::HISTORY), booking: Assistant::Booking.new(conversation))
    prompt = brain.system_prompt

    expect(prompt).to include('a software company', 'PRODUCT', 'Lead Prospecting', 'Send a text campaign',
                              "[V#{shared_video.id}] Text campaigns", 'Never state a price', '30 minute demo by video call', 'DEMOS: you book demos yourself', 'with Tom')
    expect(prompt).not_to include("[V#{private_video.id}]")
    expect(prompt).not_to include('HOMES (the only homes')
    expect(prompt).not_to match(/—|–/)
  end

  it 'keeps the home dealer prompt for everyone else' do
    company.update!(industry: 'manufactured_housing')
    prompt = Assistant::Brain.new(conversation: conversation, settings: Assistant::Settings.for(company), history: []).system_prompt
    expect(prompt).to include('a manufactured home dealer', 'HOMES (the only homes')
    expect(prompt).not_to include('PRODUCT (the add-ons')
  end

  it 'puts a Watch button for the video under the reply, starting at the right moment' do
    video = { id: shared_video.id, title: 'Text campaigns', start: 42,
              url: Assistant::Software.watch_url(shared_video, 42) }
    brain_says('You pick an audience and send. Want to see how that works? Here is a short video.', video: video)

    Assistant::WebChat.new(conversation).visitor_says!('How do text campaigns work?')

    message = conversation.chat_messages.where(direction: 'outbound').last
    expect(message.actions.first).to include('type' => 'link', 'label' => 'Watch: Text campaigns')
    expect(message.actions.first['url']).to end_with("/watch/#{shared_video.share_token}?t=42")
  end

  it 'books the demo with the chosen person on their video link, whoever owns the lead' do
    travel_to(Time.find_zone('America/Denver').local(2026, 11, 9, 8, 0)) do
      slot = Assistant::Booking.new(conversation).slots.first
      expect(Assistant::Booking.new(conversation).rep).to eq(tom)
      brain_says('Great, talk then.', book_slot: slot.id)

      Assistant::WebChat.new(conversation).visitor_says!('The first one works')

      demo = LeadActivity.where(lead_id: lead.id, activity_type: 'meeting').last
      expect(demo).to have_attributes(assigned_to_id: tom.id, subject: 'Demo: Tia May', meeting_location: 'https://zoom.us/j/123456',
                                      duration_minutes: 30)
      expect(demo.description).to include('Join the video call: https://zoom.us/j/123456')
      reply = conversation.chat_messages.where(direction: 'outbound').last.body
      expect(reply).to include('on a video call: https://zoom.us/j/123456', 'with Tom')

      customer = Appointments::Customer.for(demo)
      expect(Appointments::BookingText.body(demo, customer, tom, 'booked'))
        .to include('by video call (the link to join is in your email invite)')
      expect(Appointments::BookingText.body(demo, customer, tom, 'booked')).not_to include('https://')
    end
  end

  it 'says only that it is a video call when the person has no link yet' do
    tom.update!(meeting_url: nil)
    travel_to(Time.find_zone('America/Denver').local(2026, 11, 9, 8, 0)) do
      slot = Assistant::Booking.new(conversation).slots.first
      brain_says('Great.', book_slot: slot.id)
      Assistant::WebChat.new(conversation).visitor_says!('That works')
      demo = LeadActivity.where(lead_id: lead.id, activity_type: 'meeting').last
      expect(demo.meeting_location).to eq('Video call')
      expect(conversation.chat_messages.where(direction: 'outbound').last.body).to include('by video call')
    end
  end
end

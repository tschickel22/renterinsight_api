# frozen_string_literal: true

require 'rails_helper'

# Proactive Outreach learns from what people do (E105, 2026-11-20): link
# previews do not count as clicks, a real click brings the next message forward
# and shapes it, and an email that bounced is not used again.
RSpec.describe 'Proactive Outreach engagement', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:owner) do
    User.create!(email: "o-#{SecureRandom.hex(4)}@example.com", first_name: 'Tom', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'company_admin', status: 'active')
  end
  let(:lead) { company.leads.create!(first_name: 'Chad', last_name: 'M', email: 'chad@example.com', phone: '3035550111', owner_id: owner.id, status: 'new') }
  let(:wave) { company.outreach_waves.create!(name: 'W', status: 'running', started_at: 1.day.ago, channels: 'both', first_channel: 'text') }
  let(:item) { company.outreach_content_items.create!(title: 'TrueBuild on your site', url: 'https://vimeo.com/9', status: 'approved') }
  let(:sent_at) { Time.zone.parse('2026-11-20 18:55:03') }
  let(:target) do
    t = wave.outreach_targets.create!(company_id: company.id, lead_id: lead.id, channel: 'text', test_group: 'contact', status: 'sent',
                                      touch_count: 1, last_channel: 'text', first_sent_at: sent_at, last_sent_at: sent_at, next_touch_at: sent_at + 1.day)
    t.record!('sent', channel: 'text', at: sent_at, metadata: { content_item_id: item.id })
    t
  end
  let(:phone) { 'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/120 Mobile Safari/537.36' }

  def visit(at, ip:, agent: phone)
    travel_to(at) do
      get URI(Outreach::Tracking.short_video_url(target, item)).path, headers: { 'User-Agent' => agent, 'CF-Connecting-IP' => ip }
    end
    expect(response).to have_http_status(:found)
  end

  it 'does not count the Google preview that opened Chad\'s link seconds after the text' do
    visit(sent_at + 3.seconds, ip: '74.125.213.7')
    visit(sent_at + 17.seconds, ip: '192.178.15.196')
    visit(sent_at + 4.minutes, ip: '74.125.213.9')
    expect(target.outreach_events.where(event_type: 'clicked')).to be_empty
    expect(target.reload.first_click_at).to be_nil
    expect(target.next_touch_at).to eq(sent_at + 1.day)
  end

  it 'counts a person, notes the text, and brings the next message forward, once' do
    visit(sent_at + 30.minutes, ip: '98.37.10.4')
    click = target.outreach_events.find_by(event_type: 'clicked')
    expect(click).to have_attributes(channel: 'text')
    expect(click.metadata).to include('ip' => '98.37.10.4', 'content_item_id' => item.id)
    # Not sooner than 20 hours after the last message, even though they clicked.
    expect(target.reload.next_touch_at).to eq(sent_at + 20.hours)

    target.update!(next_touch_at: sent_at + 3.days, last_sent_at: sent_at)
    visit(sent_at + 2.days, ip: '98.37.10.4')
    expect(target.reload.next_touch_at).to eq(sent_at + 3.days)
  end

  it 'brings a later follow-up to two hours after the click' do
    target.update!(next_touch_at: sent_at + 7.days)
    visit(sent_at + 2.days, ip: '98.37.10.4')
    expect(target.reload.next_touch_at).to eq(sent_at + 2.days + 2.hours)
  end

  it 'takes the early clicks already recorded out' do
    target.record!('clicked', at: sent_at + 3.seconds, metadata: { content_item_id: item.id })
    target.update!(first_click_at: sent_at + 3.seconds)
    target.record!('clicked', at: sent_at + 2.hours, metadata: { content_item_id: item.id })

    expect(Outreach::LinkVisit.reclassify!).to eq(1)
    expect(target.outreach_events.where(event_type: 'clicked').count).to eq(1)
    expect(target.reload.first_click_at).to be_within(1.second).of(sent_at + 2.hours)
  end

  it 'follows up on the channel they acted on, within the text limit' do
    reach = Outreach::Eligibility::Reach.new(text: true, email: true)
    expect(wave.next_channel(reach, last: 'text')).to eq('email')
    expect(wave.next_channel(reach, last: 'text', prefer: 'text', texts_sent: 1)).to eq('text')
    expect(wave.next_channel(reach, last: 'text', prefer: 'text', texts_sent: 2)).to eq('email')
  end

  it 'stops emailing an address that bounced' do
    eligibility = Outreach::Eligibility.new(company)
    expect(eligibility.reach(lead).email).to be(true)
    Communication.create!(company_id: company.id, communicable: lead, channel: 'email', direction: 'outbound', status: 'bounced',
                          to_address: 'Chad@example.com', from_address: 'tom@example.com', subject: 'Hi', body: 'Hi')
    expect(Outreach::Eligibility.new(company).reach(lead).email).to be(false)
  end

  it 'tells the writer what they did, and to stay on the problem they watched' do
    TenantModuleOverride.create!(company: company, module_key: 'marketing.proactive_outreach', is_enabled: true)
    target.record!('clicked', channel: 'text', at: sent_at + 2.hours, metadata: { content_item_id: item.id })
    prompt = nil
    allow(Outreach::AiClient).to receive(:call) do |**args|
      prompt = args[:system]
      { 'body' => 'Would a 30 minute look this week help?', 'subject' => 'Pricing on your floor plans' }
    end
    Outreach::Writer.new(target).follow_up('email', number: 1, of: 6)
    expect(prompt).to include('WHAT THEY DID WITH YOUR MESSAGES', 'They watched "TrueBuild on your site"', 'do NOT switch to a new problem')
    expect(prompt).not_to include('Use a different problem')
  end

  it 'tells the writer to change the topic when emails are opened but nothing is clicked' do
    target.record!('sent', channel: 'email', at: sent_at + 1.day, communication_id: 1)
    target.record!('opened', channel: 'email', at: sent_at + 1.day + 1.hour, communication_id: 1)
    expect(Outreach::Engagement.new(target).prompt_lines).to include('opened your emails but not clicked')
  end
end

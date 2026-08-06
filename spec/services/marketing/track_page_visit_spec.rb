# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marketing::TrackPageVisit do
  let(:company) { Company.create!(name: "Trk-#{SecureRandom.hex(4)}") }
  let(:site) { Marketing::MarketingSiteProvisioner.call(company: company) }
  let(:page) { site.website_pages.create!(title: 'Spring Sale', path: '/spring-sale', page_kind: 'landing') }

  let(:request) do
    instance_double(ActionDispatch::Request, user_agent: 'Mozilla/5.0 (Macintosh)', remote_ip: '203.0.113.9')
  end

  def track(params)
    described_class.new(page: page, params: params.with_indifferent_access, request: request).call
  end

  let(:base) { { visitor_token: 'v-1', session_token: 's-1' } }

  describe 'creating a visit' do
    it 'records the session with attribution and device' do
      visit = track(base.merge(
        referrer: 'https://mail.example.com/',
        utm_source: 'email', utm_medium: 'campaign', utm_campaign: 'spring'
      ))

      expect(visit).to be_persisted
      expect(visit.company_id).to eq(company.id)
      expect(visit.website_page_id).to eq(page.id)
      expect(visit.utm_source).to eq('email')
      expect(visit.device_type).to eq('desktop')
      expect(visit.first_seen_at).to be_present
    end

    # The beacon fires several times per session. Each flush must land on the
    # same visit or a single visitor becomes four.
    it 'reuses the visit for the same session token' do
      first = track(base)
      second = track(base)

      expect(second.id).to eq(first.id)
      expect(PageVisit.where(website_page_id: page.id).count).to eq(1)
    end

    it 'starts a new visit for a new session from the same visitor' do
      track(base)
      second = track(base.merge(session_token: 's-2'))

      expect(PageVisit.where(visitor_token: 'v-1').count).to eq(2)
      expect(second.visitor_token).to eq('v-1')
    end

    it 'requires both tokens' do
      expect { track(visitor_token: 'v-1') }.to raise_error(described_class::TrackingError)
      expect { track(session_token: 's-1') }.to raise_error(described_class::TrackingError)
    end
  end

  describe 'privacy' do
    # An IP is personal data and nothing here needs to reverse it.
    it 'stores a hash of the IP, never the address' do
      visit = track(base)

      expect(visit.ip_hash).to be_present
      expect(visit.ip_hash).not_to include('203.0.113.9')
      expect(visit.ip_hash.length).to eq(64)
    end

    it 'hashes the same IP consistently and different IPs differently' do
      a = track(base)
      other = instance_double(ActionDispatch::Request, user_agent: 'Mozilla/5.0', remote_ip: '198.51.100.4')
      b = described_class.new(page: page, params: base.merge(session_token: 's-2').with_indifferent_access,
                              request: other).call

      expect(a.ip_hash).not_to eq(b.ip_hash)
    end
  end

  describe 'bot filtering' do
    it 'flags obvious crawlers rather than dropping them' do
      bot = instance_double(ActionDispatch::Request, user_agent: 'Googlebot/2.1', remote_ip: '203.0.113.9')
      visit = described_class.new(page: page, params: base.with_indifferent_access, request: bot).call

      expect(visit.is_bot).to be(true)
      expect(PageVisit.real).not_to include(visit)
    end

    it 'does not flag an ordinary browser' do
      expect(track(base).is_bot).to be(false)
    end
  end

  describe 'events' do
    it 'inserts the batch' do
      visit = track(base.merge(events: [
        { type: 'view', at: 1_700_000_000_000 },
        { type: 'scroll_50' },
        { type: 'video_play', payload: { 'src' => 'x.mp4' } }
      ]))

      expect(visit.page_visit_events.pluck(:event_type)).to contain_exactly('view', 'scroll_50', 'video_play')
      expect(visit.page_visit_events.find_by(event_type: 'video_play').payload).to eq('src' => 'x.mp4')
    end

    # A newer client sending an event this server does not know about should
    # not cost the events it does know.
    it 'drops unknown event types without failing the batch' do
      visit = track(base.merge(events: [{ type: 'view' }, { type: 'telepathy' }]))

      expect(visit.page_visit_events.pluck(:event_type)).to eq(['view'])
    end

    it 'accumulates events across flushes' do
      track(base.merge(events: [{ type: 'view' }]))
      visit = track(base.merge(events: [{ type: 'scroll_50' }]))

      expect(visit.page_visit_events.count).to eq(2)
    end
  end

  describe 'progress' do
    it 'keeps the deepest scroll and longest duration' do
      track(base.merge(max_scroll_depth: 75, duration_ms: 9_000))
      visit = track(base.merge(max_scroll_depth: 25, duration_ms: 2_000))

      expect(visit.max_scroll_depth).to eq(75)
      expect(visit.duration_ms).to eq(9_000)
    end

    it 'advances them when the new values are higher' do
      track(base.merge(max_scroll_depth: 25, duration_ms: 2_000))
      visit = track(base.merge(max_scroll_depth: 100, duration_ms: 30_000))

      expect(visit.max_scroll_depth).to eq(100)
      expect(visit.duration_ms).to eq(30_000)
    end

    it 'marks the visit converted on form_submit' do
      visit = track(base.merge(events: [{ type: 'form_submit' }]))
      expect(visit.reload.converted).to be(true)
    end
  end

  describe 'campaign attribution' do
    let(:user) do
      User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                   password: 'Pass1234!', company_id: company.id)
    end
    let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
    let(:lead) do
      Lead.create!(company: company, source: source, first_name: 'B', last_name: 'One',
                   email: "b-#{SecureRandom.hex(4)}@example.com")
    end
    let(:campaign) do
      Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                       campaign_type: 'blast', from_identity_type: 'User',
                       from_identity_id: user.id, throttle_per_day: 100)
    end
    let(:step) { campaign.campaign_steps.create!(position: 0, is_active: true, body_blocks: [{ 'type' => 'text', 'html' => 'x' }]) }
    let(:enrollment) do
      CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id,
                                 recipient_type: 'Lead', recipient_id: lead.id,
                                 email_address_snapshot: lead.email)
    end
    let(:send_row) do
      CampaignSend.create!(company_id: company.id, campaign_id: campaign.id,
                           campaign_step_id: step.id, campaign_enrollment_id: enrollment.id)
    end
    let(:link) do
      CampaignLinkToken.create!(campaign_id: campaign.id, campaign_send_id: send_row.id,
                               target_url: 'https://example.com/spring-sale')
    end

    # Someone arriving from a campaign email is already resolvable — no
    # fingerprinting, no guessing.
    it 'identifies a visitor arriving on a campaign link token' do
      visit = track(base.merge(campaign_token: link.token))

      expect(visit.identified_entity).to eq(lead)
      expect(visit.campaign_enrollment_id).to eq(enrollment.id)
      expect(visit.campaign_id).to eq(campaign.id)
      expect(visit).to be_identified
    end

    it 'falls back to the page campaign for an unknown token' do
      page.update!(campaign_id: campaign.id)
      visit = track(base.merge(campaign_token: 'not-a-real-token'))

      expect(visit.campaign_id).to eq(campaign.id)
      expect(visit.identified_entity).to be_nil
    end

    it 'leaves an ordinary visitor anonymous' do
      expect(track(base).identified_entity).to be_nil
    end
  end
end

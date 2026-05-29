# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Api::V1::Campaigns engagement breakdown', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: "Rep", last_name: "One",
                 password: "Pass1234!", company_id: company.id, role: "platform_admin")
  end
  let(:token) { JsonWebToken.encode(user_id: user.id, company_id: company.id) }
  let(:headers) { { "Authorization" => "Bearer #{token}" } }
  let(:source) { Source.find_or_create_by!(name: "Web") { |s| s.source_type = "web" } }
  let(:campaign) do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: "C",
                     campaign_type: "drip", from_identity_type: "User", from_identity_id: user.id, throttle_per_day: 100)
  end
  let(:step1) { campaign.campaign_steps.create!(position: 0, is_active: true, channel: 'email', subject: 'Step 1', body_blocks: [{ "type" => "text", "html" => "x" }]) }
  let(:step2) { campaign.campaign_steps.create!(position: 1, is_active: true, channel: 'email', subject: 'Step 2', body_blocks: [{ "type" => "text", "html" => "x" }]) }

  def make_lead
    Lead.create!(company: company, source: source, first_name: "L#{SecureRandom.hex(2)}", last_name: "X",
                 email: "l-#{SecureRandom.hex(4)}@example.com", phone: "555-0000", owner_id: user.id)
  end

  def enroll(lead, meta: {})
    CampaignEnrollment.create!(company_id: company.id, campaign_id: campaign.id, recipient_type: "Lead",
                               recipient_id: lead.id, email_address_snapshot: lead.email, metadata: meta)
  end

  def make_comm(lead)
    Communication.create!(company_id: company.id, communicable: lead, channel: 'email', direction: 'outbound',
                          subject: 'S', body: 'B', from_address: 'a@example.com', to_address: lead.email, status: 'sent')
  end

  def make_send(enr, step, comm:, opened: false, clicked: false, replied: false, opens: 0, clicks: 0)
    CampaignSend.create!(company_id: company.id, campaign_id: campaign.id, campaign_step_id: step.id,
                         campaign_enrollment_id: enr.id, communication_id: comm&.id,
                         sent_at: 2.hours.ago, delivered_at: 1.hour.ago,
                         opened_at: (opened ? 1.hour.ago : nil), open_count: opens,
                         clicked_at: (clicked ? 30.minutes.ago : nil), click_count: clicks,
                         replied_at: (replied ? 20.minutes.ago : nil))
  end

  def content_link(send_rec, url, clicks: 1)
    t = CampaignLinkToken.create!(campaign_id: campaign.id, campaign_send_id: send_rec.id, target_url: url)
    t.update_columns(click_count: clicks, first_clicked_at: 1.hour.ago, last_clicked_at: 10.minutes.ago) if clicks.positive?
    t
  end

  def attachment_link(comm, filename:, clicks: 1)
    TrackedLink.create!(company_id: company.id, communication_id: comm.id, filename: filename,
                        link_type: 'attachment', click_count: clicks, last_clicked_at: 5.minutes.ago)
  end

  # A clicked + opened recipient on step1 with a content link and an attachment link.
  def engaged_recipient(content_url: 'https://example.com/pricing', attachment: 'Deck.pdf', clicks: 2)
    lead = make_lead
    enr  = enroll(lead)
    comm = make_comm(lead)
    s    = make_send(enr, step1, comm: comm, opened: true, clicked: true, opens: 3, clicks: clicks)
    content_link(s, content_url, clicks: clicks)
    attachment_link(comm, filename: attachment, clicks: 1)
    { lead: lead, enrollment: enr, send: s }
  end

  describe 'GET /api/v1/campaigns/:id/engagement/by_step' do
    it 'requires auth' do
      get "/api/v1/campaigns/#{campaign.id}/engagement/by_step"
      expect(response).to have_http_status(:unauthorized)
    end

    it 'returns empty items/stats when there is no engagement' do
      step1
      get "/api/v1/campaigns/#{campaign.id}/engagement/by_step", headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["items"]).to eq([])
      expect(body["meta"]["stats"]).to include("steps" => 0, "total_sent" => 0, "total_clicks" => 0)
    end

    it 'aggregates sent/opens/clicks/replies per step with rates' do
      lead = make_lead; enr = enroll(lead); comm = make_comm(lead)
      make_send(enr, step1, comm: comm, opened: true, clicked: true, replied: true, opens: 4, clicks: 2)

      get "/api/v1/campaigns/#{campaign.id}/engagement/by_step", headers: headers
      body = JSON.parse(response.body)
      item = body["items"].find { |i| i["step_id"] == step1.id }
      expect(item["sent"]).to eq(1)
      expect(item["opens"]).to eq(4)
      expect(item["unique_openers"]).to eq(1)
      expect(item["open_rate"]).to eq(1.0)
      expect(item["clicks"]).to eq(2)
      expect(item["unique_clickers"]).to eq(1)
      expect(item["replies"]).to eq(1)
      expect(item["subject"]).to eq("Step 1")
    end

    it 'excludes test sends' do
      test_lead = make_lead
      test_enr  = enroll(test_lead, meta: { 'test_send' => 'true' })
      make_send(test_enr, step1, comm: make_comm(test_lead), opened: true, opens: 9, clicks: 9, clicked: true)

      get "/api/v1/campaigns/#{campaign.id}/engagement/by_step", headers: headers
      body = JSON.parse(response.body)
      expect(body["items"]).to eq([])
      expect(body["meta"]["stats"]["total_clicks"]).to eq(0)
    end

    it 'caps top_links per step' do
      stub_const("Campaigns::EngagementBreakdown::TOP_LINKS_PER_STEP", 2)
      lead = make_lead; enr = enroll(lead); comm = make_comm(lead)
      s = make_send(enr, step1, comm: comm, opened: true, clicked: true, opens: 1, clicks: 3)
      3.times { |i| content_link(s, "https://example.com/l#{i}", clicks: i + 1) }

      get "/api/v1/campaigns/#{campaign.id}/engagement/by_step?sort=clicks", headers: headers
      body = JSON.parse(response.body)
      item = body["items"].find { |i| i["step_id"] == step1.id }
      expect(item["top_links"].size).to eq(2)
      # ordered by clicks desc
      expect(item["top_links"].first["clicks"]).to be >= item["top_links"].last["clicks"]
    end

    it 'supports the position sort' do
      l1 = make_lead; make_send(enroll(l1), step2, comm: make_comm(l1), clicked: true, clicks: 5)
      l2 = make_lead; make_send(enroll(l2), step1, comm: make_comm(l2), clicked: true, clicks: 1)

      get "/api/v1/campaigns/#{campaign.id}/engagement/by_step?sort=position", headers: headers
      body = JSON.parse(response.body)
      positions = body["items"].map { |i| i["position"] }
      expect(positions).to eq(positions.sort)
    end
  end

  describe 'GET /api/v1/campaigns/:id/engagement/by_link' do
    it 'returns empty when nothing clicked' do
      step1
      get "/api/v1/campaigns/#{campaign.id}/engagement/by_link", headers: headers
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["items"]).to eq([])
      expect(body["meta"]["stats"]).to include("links" => 0, "total_clicks" => 0)
    end

    it 'lists links with the recipients who clicked them' do
      r = engaged_recipient(content_url: 'https://example.com/pricing', clicks: 2)

      get "/api/v1/campaigns/#{campaign.id}/engagement/by_link?sort=clicks", headers: headers
      body = JSON.parse(response.body)
      pricing = body["items"].find { |i| i["url"] == "https://example.com/pricing" }
      expect(pricing["kind"]).to eq("content_link")
      expect(pricing["total_clicks"]).to eq(2)
      expect(pricing["unique_clickers"]).to eq(1)
      recip = pricing["recipients"].first
      expect(recip["recipient_id"]).to eq(r[:lead].id)
      expect(recip["click_count"]).to eq(2)
      expect(recip["phone"]).to eq("555-0000")
      expect(recip["owner_name"]).to eq("Rep One")
      expect(recip["link"]).to eq("/crm/leads/#{r[:lead].id}")

      # attachment link is classified as 'attachment'
      deck = body["items"].find { |i| i["label"] == "Deck.pdf" }
      expect(deck["kind"]).to eq("attachment")
    end

    it 'filters to one step via step_id' do
      # link on step1
      l1 = make_lead; e1 = enroll(l1); c1 = make_comm(l1)
      s1 = make_send(e1, step1, comm: c1, clicked: true, clicks: 1)
      content_link(s1, 'https://example.com/step1-link', clicks: 1)
      # link on step2
      l2 = make_lead; e2 = enroll(l2); c2 = make_comm(l2)
      s2 = make_send(e2, step2, comm: c2, clicked: true, clicks: 1)
      content_link(s2, 'https://example.com/step2-link', clicks: 1)

      get "/api/v1/campaigns/#{campaign.id}/engagement/by_link?step_id=#{step1.id}", headers: headers
      body = JSON.parse(response.body)
      urls = body["items"].map { |i| i["url"] }
      expect(urls).to include("https://example.com/step1-link")
      expect(urls).not_to include("https://example.com/step2-link")
      expect(body["items"].map { |i| i["step_id"] }.uniq).to eq([step1.id])
    end

    it 'caps recipients per link and sets recipients_truncated' do
      stub_const("Campaigns::EngagementBreakdown::MAX_RECIPIENTS_PER_LINK", 2)
      3.times { engaged_recipient(content_url: 'https://example.com/shared', attachment: "A#{SecureRandom.hex(2)}.pdf", clicks: 1) }

      get "/api/v1/campaigns/#{campaign.id}/engagement/by_link", headers: headers
      body = JSON.parse(response.body)
      shared = body["items"].find { |i| i["url"] == "https://example.com/shared" }
      expect(shared["unique_clickers"]).to eq(3)
      expect(shared["recipients"].size).to eq(2)
      expect(shared["recipients_truncated"]).to be(true)
    end

    it 'paginates' do
      3.times { |i| engaged_recipient(content_url: "https://example.com/p#{i}", attachment: "D#{i}.pdf", clicks: 1) }

      get "/api/v1/campaigns/#{campaign.id}/engagement/by_link?per_page=2&page=1", headers: headers
      body = JSON.parse(response.body)
      expect(body["items"].size).to eq(2)
      expect(body["meta"]["total"]).to be >= 4 # 3 content links + 3 attachments
      expect(body["meta"]["total_pages"]).to be >= 2
    end
  end
end

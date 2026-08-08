# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::DemoEngagement do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:profile) do
    SiteContentProfile.create!(company: company, source_url: 'https://dealer.com',
                               status: 'ready', source_kind: 'url')
  end

  def open_demo(visitor:, session: SecureRandom.hex(4), template: nil, internal: false, at: Time.current)
    travel_to(at) do
      SiteProfileView.record!(profile: profile, session_token: session, visitor_token: visitor,
                              template_id: template, attributes: { is_internal: internal,
                                                                   device_type: 'desktop' })
    end
  end

  subject(:report) { described_class.new(profile).call }

  describe 'a demo nobody opened' do
    it 'says so without pretending there is data' do
      expect(report[:opens]).to eq(0)
      expect(report[:viewers]).to eq(0)
      expect(report[:first_opened_at]).to be_nil
      expect(report[:designs]).to eq([])
    end
  end

  describe 'counting opens' do
    it 'counts one row per session, not per beacon' do
      session = SecureRandom.hex(4)
      3.times { open_demo(visitor: 'v1', session: session, template: 'coastal') }

      expect(report[:opens]).to eq(1)
      expect(report[:sessions].first[:view_events]).to eq(3)
    end

    # One visit is curiosity, three is a shortlist. That is the signal, and it
    # only exists if a returning viewer is recognisable as the same person.
    it 'recognises someone who came back in a later session' do
      open_demo(visitor: 'v1', session: 's1')
      open_demo(visitor: 'v1', session: 's2')
      open_demo(visitor: 'v2', session: 's3')

      expect(report[:opens]).to eq(3)
      expect(report[:viewers]).to eq(2)
      expect(report[:returning_viewers]).to eq(1)
    end

    it 'records when it was first and last looked at' do
      open_demo(visitor: 'v1', session: 's1', at: 3.days.ago)
      open_demo(visitor: 'v1', session: 's2', at: 1.hour.ago)

      expect(Time.parse(report[:first_opened_at])).to be_within(1.minute).of(3.days.ago)
      expect(Time.parse(report[:last_opened_at])).to be_within(1.minute).of(1.hour.ago)
    end
  end

  # "The prospect never opened it" and "nobody opened it" are different
  # conversations, so ours are counted rather than dropped.
  describe 'our own previews' do
    it 'keeps them out of the prospect counts but still reports them' do
      open_demo(visitor: 'admin', session: 'a1', internal: true)
      open_demo(visitor: 'prospect', session: 'p1')

      expect(report[:opens]).to eq(1)
      expect(report[:internal_opens]).to eq(1)
    end
  end

  describe 'which design held their attention' do
    it 'ranks designs by how often they were looked at' do
      open_demo(visitor: 'v1', session: 's1', template: 'coastal')
      open_demo(visitor: 'v1', session: 's1', template: 'coastal')
      open_demo(visitor: 'v2', session: 's2', template: 'coastal')
      open_demo(visitor: 'v2', session: 's2', template: 'elite')

      expect(report[:designs]).to eq([
        { template_id: 'coastal', views: 3 },
        { template_id: 'elite', views: 1 }
      ])
    end

    it 'ignores our own previews when ranking' do
      open_demo(visitor: 'admin', session: 'a1', template: 'elite', internal: true)

      expect(report[:designs]).to eq([])
    end
  end

  describe 'the session list' do
    # Three opens in one afternoon reads differently from three across a
    # fortnight, and only the individual visits show that.
    it 'lists visits newest first with what they looked at' do
      open_demo(visitor: 'v1', session: 's1', template: 'coastal', at: 2.days.ago)
      open_demo(visitor: 'v2', session: 's2', template: 'elite', at: 1.hour.ago)

      expect(report[:sessions].first[:designs]).to eq(['elite'])
      expect(report[:sessions].last[:designs]).to eq(['coastal'])
    end
  end

  describe 'SiteProfileView.record!' do
    it 'is inert without the tokens that identify a session' do
      expect(SiteProfileView.record!(profile: profile, session_token: nil, visitor_token: 'v')).to be_nil
      expect(SiteProfileView.record!(profile: nil, session_token: 's', visitor_token: 'v')).to be_nil
    end

    # The showcase fires on first paint and again on the first design change,
    # which can race. The unique index would turn that into a 500 on a
    # prospect's screen.
    it 'survives two beacons racing on the same session' do
      expect {
        2.times { SiteProfileView.record!(profile: profile, session_token: 'same', visitor_token: 'v1') }
      }.to change(SiteProfileView, :count).by(1)
    end
  end
end

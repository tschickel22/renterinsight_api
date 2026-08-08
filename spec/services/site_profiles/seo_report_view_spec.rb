# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SiteProfiles::SeoReportView do
  let(:report) do
    {
      'domain' => 'dealer.com',
      'score' => 62,
      'gap_count' => 1,
      'pages_checked' => 10,
      'checks' => [
        {
          'key' => 'descriptions',
          'label' => 'Meta descriptions',
          'status' => 'fail',
          'headline' => '6 pages with no meta description',
          'detail' => 'The description is the sales pitch under the link in search results.',
          'urls' => %w[https://dealer.com/a https://dealer.com/b https://dealer.com/c],
          'weight' => 7
        }
      ]
    }
  end

  describe '.client' do
    subject(:view) { described_class.client(report) }

    # The whole reason this exists. A prospect handed page addresses forwards
    # them to whoever built the site, that agency fixes it for free, and the
    # reason to switch is gone.
    it 'withholds the page addresses' do
      expect(view['checks'].first).not_to have_key('urls')
    end

    # Still concrete enough to be believed and checked, without being a work
    # order.
    it 'keeps the finding, the severity and how much is affected' do
      check = view['checks'].first

      expect(check['label']).to eq('Meta descriptions')
      expect(check['status']).to eq('fail')
      expect(check['headline']).to include('6 pages')
      expect(check['affected_count']).to eq(3)
    end

    it 'keeps the score and the domain, which are what open the conversation' do
      expect(view['score']).to eq(62)
      expect(view['domain']).to eq('dealer.com')
    end

    it 'marks itself as the client view, so it cannot be mistaken for the whole picture' do
      expect(view['audience']).to eq('client')
    end

    it 'is nil when there is nothing to show' do
      expect(described_class.client(nil)).to be_nil
      expect(described_class.client({})).to be_nil
    end
  end

  describe '.internal' do
    it 'keeps everything, because a rep needs specifics and we have to fix them' do
      check = described_class.internal(report)['checks'].first

      expect(check['urls']).to eq(%w[https://dealer.com/a https://dealer.com/b https://dealer.com/c])
      expect(check['detail']).to be_present
    end
  end

  describe 'the shared demo payload' do
    let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
    let(:profile) do
      SiteContentProfile.create!(company: company, source_url: 'https://dealer.com', status: 'ready',
                                 source_kind: 'url', seo_report: report, show_seo_report: true)
    end

    # This was live: the demo sent the full report, addresses and all.
    it 'sends the client view, never the addresses' do
      payload = SiteProfiles::SeoReportView.client(profile.seo_report)

      expect(payload['checks'].first).not_to have_key('urls')
      expect(payload.to_json).not_to include('dealer.com/a')
    end
  end
end

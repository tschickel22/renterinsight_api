# frozen_string_literal: true

require 'rails_helper'

# The paragraph is written to be the first thing anyone reads. Sending the
# record straight out meant it was the one thing we could not read without
# exporting a PDF, which is exactly what it exists to save.
RSpec.describe 'the SEO report an admin is sent' do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:report) do
    {
      'domain' => 'mobilehomemasters.com', 'score' => 64, 'pages_checked' => 10,
      'checks' => [
        { 'key' => 'local_business', 'label' => 'Local business markup', 'status' => 'fail',
          'headline' => 'No local business markup', 'weight' => 9, 'urls' => ['https://x/a'] }
      ]
    }
  end
  let(:profile) do
    SiteContentProfile.create!(company: company, source_url: 'https://mobilehomemasters.com',
                               status: 'ready', source_kind: 'url', seo_report: report)
  end

  it 'carries the summary, so the panel can show what the PDF shows' do
    view = SiteProfiles::SeoReportView.internal(profile.seo_report)

    expect(view['summary']).to include('scores 64 out of 100')
    expect(view['summary']).to include('Nothing tells Google this is a dealership')
  end

  # The admin view is ours: the page addresses are what make it actionable.
  it 'still keeps the specifics an admin needs' do
    view = SiteProfiles::SeoReportView.internal(profile.seo_report)

    expect(view['checks'].first['urls']).to eq(['https://x/a'])
  end
end

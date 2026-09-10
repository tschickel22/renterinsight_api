# frozen_string_literal: true

require 'rails_helper'

# What a failed scan tells the admin.
#
# The first version of this message covered four different failures with one
# guess — "usually a bot check or a site whose text is drawn entirely by
# JavaScript" — and when it fired in production it sent us looking in the wrong
# place. A browser that never started, a bot check that never cleared and a page
# that never hydrated look identical from outside and want opposite fixes.
RSpec.describe SiteProfiles::Orchestrator do
  let(:profile) do
    SiteContentProfile.create!(company: create(:company), source_url: 'https://thehomeplus.com',
                               status: 'pending')
  end

  def message_for(outcome, from_archive: false)
    fetcher = instance_double(SiteProfiles::Fetcher,
                              render_notes: { 'https://thehomeplus.com' => outcome })
    root = SiteProfiles::Fetcher::Response.new(url: 'https://thehomeplus.com', status: 200,
                                               body: '', content_type: 'text/html',
                                               from_archive: from_archive)
    described_class.new(profile, fetcher: fetcher).send(:unreadable_message, root)
  end

  it 'says so when rendering was never switched on' do
    expect(message_for(:off)).to include('SITE_SCAN_RENDERER=chrome')
  end

  it 'distinguishes a browser that could not start' do
    expect(message_for(:unavailable)).to include('failed to start on this server')
  end

  # The production case. A checkpoint that clears instantly from a laptop can
  # refuse a datacenter address all day, and that is worth saying out loud
  # rather than leaving someone to re-test from their desk and see it work.
  it 'distinguishes a bot check that would not clear for the server' do
    expect(message_for(:still_challenged))
      .to include('did not clear even in a real browser', 'refusing this server')
  end

  it 'distinguishes a page that rendered but drew nothing' do
    expect(message_for(:rendered)).to include('never drew any content')
  end

  it 'still explains a placeholder in the archive when no render was tried' do
    expect(message_for(nil, from_archive: true)).to include('web archive holds only a placeholder')
  end

  it 'always names the site and what to do instead' do
    expect(message_for(:still_challenged)).to start_with('thehomeplus.com')
    expect(message_for(:still_challenged)).to include('Upload a brochure')
  end
end

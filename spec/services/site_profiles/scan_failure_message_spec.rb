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

  def message_for(outcome, from_archive: false, root: :page)
    fetcher = instance_double(SiteProfiles::Fetcher,
                              render_notes: { 'https://thehomeplus.com' => outcome })
    response = if root == :page
                 SiteProfiles::Fetcher::Response.new(url: 'https://thehomeplus.com', status: 200,
                                                     body: '', content_type: 'text/html',
                                                     from_archive: from_archive)
               end
    described_class.new(profile, fetcher: fetcher).send(:unreadable_message, response)
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
    expect(message_for(:still_challenged)).to include('will not clear for this server')
  end

  # Every other explanation was eliminated by measurement — user agent, wait,
  # and browser binary all clear the same site in a tenth of a second from a
  # home connection. So the message points at the route that works instead of
  # inviting another round of tuning.
  it 'points at scanning from a machine that can reach the site' do
    message = message_for(:still_challenged)

    expect(message).to include('site_scan:push')
    expect(message).to include('refusing this machine rather than the browser')
  end

  # A UI message is read by whoever pressed the button, and an environment
  # variable name tells them nothing they can act on.
  it 'keeps environment variable names out of it' do
    expect(message_for(:still_challenged)).not_to include('SITE_SCAN_RENDER_TOKEN')
  end

  # Every other failure still ends the way it did: those are not fixed by
  # running the same scan somewhere else.
  it 'offers the brochure route for failures a different machine would not fix' do
    expect(message_for(:rendered)).to include('Upload a brochure')
    expect(message_for(:rendered)).not_to include('site_scan:push')
  end

  it 'distinguishes a page that rendered but drew nothing' do
    expect(message_for(:rendered)).to include('never drew any content')
  end

  it 'still explains a placeholder in the archive when no render was tried' do
    expect(message_for(nil, from_archive: true)).to include('web archive holds only a placeholder')
  end

  # The failure production actually reported. Reaching the archive means the
  # live site refused us AND the browser failed, and the second half is the only
  # actionable one — reporting the archive alone hid it for a whole deploy.
  it 'names the browser failure even when the archive answered' do
    message = message_for(:still_challenged, from_archive: true)

    expect(message).to include('will not clear for this server')
    expect(message).to include('web archive holds only a placeholder')
  end

  it 'names a browser that would not start even when the archive answered' do
    expect(message_for(:unavailable, from_archive: true)).to include('failed to start on this server')
  end

  # What production said on the second attempt: the fetch, the browser and the
  # archive had all been tried and the only thing reported was "Could not load
  # https://thehomeplus.com", which names none of them.
  it 'explains a page that never arrived at all' do
    expect(message_for(nil, root: nil)).to include('could not be loaded at all')
    expect(message_for(nil, root: nil)).not_to eq('Could not load https://thehomeplus.com')
  end

  it 'still names the bot check when nothing could be loaded because of one' do
    expect(message_for(:still_challenged, root: nil)).to include('will not clear for this server')
  end

  it 'always names the site and what to do instead' do
    expect(message_for(:still_challenged)).to start_with('thehomeplus.com')
    # For this failure the route that works is a different machine; the brochure
    # is the fallback after it, not the headline.
    expect(message_for(:still_challenged)).to include('upload a brochure')
  end
end

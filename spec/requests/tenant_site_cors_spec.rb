# frozen_string_literal: true

require 'rails_helper'

# A dealer site is served from its own origin, so every request it makes to the
# API is cross-origin. Without the right header the browser discards a perfectly
# good 200 and the page renders empty, which is exactly how this was reported:
# "the inventory is no longer available".
RSpec.describe 'Tenant site CORS', type: :request do
  let(:tenant_origin) { 'https://mhmasters-staging.mydealertide.com' }
  let(:dealer_domain) { 'https://www.somedealer.com' }
  let(:allowlisted) { 'https://staging.dealertide.com' }

  def allow_origin_for(path, origin, method: 'GET')
    send(method.downcase, path, headers: { 'HTTP_ORIGIN' => origin })
    response.headers['Access-Control-Allow-Origin']
  end

  describe 'the endpoints a published site actually calls' do
    # Enumerated from the site renderer rather than guessed. A path missing here
    # fails silently in the browser and nowhere else.
    %w[
      /public/inventory
      /public/inventory/filters
      /public/land_parcels
    ].each do |path|
      it "answers #{path} for a platform subdomain" do
        expect(allow_origin_for(path, tenant_origin)).to be_present
      end

      # The whole point of allowing any origin: a dealer's own domain cannot be
      # enumerated in an initializer.
      it "answers #{path} for a dealer's own domain" do
        expect(allow_origin_for(path, dealer_domain)).to be_present
      end
    end
  end

  it 'allows the contact button to post a lead from a tenant site' do
    expect(allow_origin_for('/public/inventory/leads', tenant_origin, method: 'POST')).to be_present
  end

  # Without this, a dealer site records no visits at all: the beacon posts to
  # the absolute API host, so it is cross-origin from every tenant hostname.
  it 'allows the tracking beacon from a tenant site' do
    expect(allow_origin_for('/pv/1', tenant_origin, method: 'POST')).to be_present
    expect(allow_origin_for('/pv/1', dealer_domain, method: 'POST')).to be_present
  end

  it 'allows the site payload endpoints without opening the rest of v1' do
    expect(allow_origin_for('/api/v1/websites/by_token/abc123', tenant_origin)).to be_present
  end

  # The guard on the block above. If this ever passes, the authenticated API is
  # readable by any page on the internet that has a session cookie.
  it 'does not open the authenticated API to an arbitrary origin' do
    expect(allow_origin_for('/api/v1/leads', dealer_domain)).to be_blank
    expect(allow_origin_for('/api/v1/websites', dealer_domain)).to be_blank
  end

  it 'leaves an allowlisted origin on the credentialed rules' do
    get '/api/v1/leads', headers: { 'HTTP_ORIGIN' => allowlisted }

    expect(response.headers['Access-Control-Allow-Origin']).to eq(allowlisted)
    expect(response.headers['Access-Control-Allow-Credentials']).to eq('true')
  end
end

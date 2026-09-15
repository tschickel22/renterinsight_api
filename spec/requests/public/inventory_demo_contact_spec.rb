# frozen_string_literal: true

require 'rails_helper'

# Whose address sits under a home on a shared demo.
#
# A demo borrows a real lot so a design can be shown with real stock in it, and
# the lot's contact details came along with the homes: a prospect in North
# Carolina read the lending dealer's Indiana address under every listing,
# directly above their own address in the footer. Asked where it came from,
# the answer was a default location — the homes carry no address of their own.
RSpec.describe 'Public inventory contact on a demo', type: :request do
  let(:lot) do
    create(:company, name: 'Acme Homes').tap do |c|
      c.update!(public_inventory_token: SecureRandom.hex(8),
                public_inventory_settings: { 'public_inventory_enabled' => true })
    end
  end
  # The company's own corporate location, which is what the contact block falls
  # back to when a home has none of its own.
  # The corporate location every company gets on create, which is what the
  # contact block falls back to when a home has no location of its own.
  let!(:showroom) do
    Location.ensure_corporate_for(lot).tap do |loc|
      loc.update!(name: 'Auburn Showroom', address_line1: '4520 Homestead Road',
                  city: 'Auburn', state: 'IN', zip_code: '46706', active: true)
    end
  end
  # No location of its own, which is how every catalog-fed home arrives.
  let!(:vehicle) do
    Vehicle.create!(company: lot, year: 2026, make: 'Clayton', model: 'EMILIE ELITE',
                    vin: "VIN#{SecureRandom.hex(6).upcase}", status: 'available',
                    is_deleted: false, location_id: nil)
  end
  let(:demo) do
    SiteContentProfile.create!(
      company: lot, source_url: 'https://thehomeplus.com', status: 'ready', source_kind: 'url',
      preview_token: SecureRandom.urlsafe_base64(24),
      display_name: 'Home + Design Studio',
      profile: {
        'brand' => { 'name' => 'Home + Design Studio' },
        'contact' => { 'address' => '16930 W Catawba Ave, Cornelius, NC 28031',
                       'phone' => '(828) 449-8896', 'email' => 'hickory@thehomeplus.com' }
      }
    )
  end

  def detail(params = {})
    get "/public/inventory/#{vehicle.id}",
        params: { token: lot.public_inventory_token, company_id: lot.id }.merge(params)
    JSON.parse(response.body)
  end

  it "shows the lot's own details when nobody says otherwise" do
    expect(detail['company']).to include('name' => 'Acme Homes', 'address' => '4520 Homestead Road')
  end

  it 'shows the dealer the demo is built for, not the lot lending the homes' do
    body = detail(demo_token: demo.preview_token)['company']

    expect(body['name']).to eq('Home + Design Studio')
    expect(body['address']).to eq('16930 W Catawba Ave, Cornelius, NC 28031')
    expect(body['phone']).to eq('(828) 449-8896')
  end

  # A scan produces one address line rather than the parts, so guessing at a
  # city and state would put a second wrong address on the page.
  it 'leaves the parts empty rather than inventing them' do
    body = detail(demo_token: demo.preview_token)['company']

    expect(body['city']).to be_nil
    expect(body['state']).to be_nil
  end

  # Proven by the token, not asserted by the caller.
  it 'ignores a token that names no demo' do
    expect(detail(demo_token: 'not-a-token')['company']).to include('name' => 'Acme Homes')
  end

  it 'ignores a demo that is no longer shareable' do
    demo.update!(status: 'pending')

    expect(detail(demo_token: demo.preview_token)['company']).to include('name' => 'Acme Homes')
  end
end

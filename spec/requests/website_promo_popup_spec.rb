# frozen_string_literal: true

require 'rails_helper'

# A dealer posts a flyer and a video (a Halloween open house, say) that greets
# visitors between two dates. The dates are judged in the visitor's browser,
# because the live page is cached at the edge; the server only cleans the input
# and drops a popup once it is over.
RSpec.describe 'Website promo popup', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}") }
  let(:location) do
    company.locations.create!(name: 'Brooksville', address_line1: '9011 McIntyre Road', city: 'Brooksville',
                              state: 'FL', zip_code: '34601', timezone: 'America/New_York')
  end
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end
  let(:auth_headers) do
    { 'Authorization' => "Bearer #{JsonWebToken.encode(user_id: user.id, company_id: company.id)}",
      'Content-Type' => 'application/json' }
  end
  let(:website) do
    company.websites.create!(location_id: location.id, name: 'Easy', slug: "s-#{SecureRandom.hex(4)}")
  end

  def save(popup)
    put "/api/v1/websites/#{website.id}/promo_popup", params: { promo_popup: popup }.to_json, headers: auth_headers
    JSON.parse(response.body)
  end

  let(:halloween) do
    { enabled: true, image_url: 'https://cdn.example.com/flyer.jpg', video_url: 'https://youtu.be/abc123',
      directions_address: '9011 McIntyre Road, Brooksville, FL 34601',
      start_date: Date.current.iso8601, end_date: (Date.current + 11).iso8601 }
  end

  it 'offers the location address and Enter Site as defaults' do
    get "/api/v1/websites/#{website.id}/promo_popup", headers: auth_headers

    body = JSON.parse(response.body)
    expect(body['promo_popup']).to eq({})
    expect(body['default_directions_address']).to eq('9011 McIntyre Road, Brooksville, FL, 34601')
    expect(body['default_enter_label']).to eq('Enter Site')
  end

  it 'saves the popup and sends it to the site with directions and the time zone' do
    save(halloween)
    expect(response).to have_http_status(:ok)

    payload = Websites::PublicPayload.for(website.reload)['promo_popup']
    expect(payload['image_url']).to eq('https://cdn.example.com/flyer.jpg')
    expect(payload['enter_label']).to eq('Enter Site')
    expect(payload['directions_url'])
      .to eq('https://www.google.com/maps/dir/?api=1&destination=9011%20McIntyre%20Road%2C%20Brooksville%2C%20FL%2034601')
    expect(payload['time_zone']).to eq('America/New_York')
  end

  it 'refuses an end date before the start date' do
    body = save(halloween.merge(start_date: '2026-10-31', end_date: '2026-10-30'))

    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to match(/end date is before/)
  end

  it 'refuses to turn on a popup with nothing in it' do
    body = save(halloween.merge(image_url: '', video_url: ''))

    expect(response).to have_http_status(:unprocessable_entity)
    expect(body['error']).to match(/flyer or a video/)
  end

  it 'refuses a link that is not a web address' do
    save(halloween.merge(video_url: 'javascript:alert(1)'))

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'sends nothing once the popup is over or turned off' do
    save(halloween.merge(start_date: '2020-10-01', end_date: '2020-10-31'))
    expect(Websites::PublicPayload.for(website.reload)['promo_popup']).to be_nil

    save(halloween.merge(enabled: false))
    expect(Websites::PublicPayload.for(website.reload)['promo_popup']).to be_nil
  end

  it 'keeps another company out' do
    other = Company.create!(name: "Other-#{SecureRandom.hex(4)}")
    site = other.websites.create!(location_id: other.locations.create!(name: 'Elsewhere').id,
                                  name: 'Theirs', slug: "o-#{SecureRandom.hex(4)}")

    put "/api/v1/websites/#{site.id}/promo_popup", params: { promo_popup: halloween }.to_json, headers: auth_headers

    expect(response).to have_http_status(:not_found)
    expect(site.reload.promo_popup).to eq({})
  end
end

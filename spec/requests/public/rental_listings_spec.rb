# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Public rental listings', type: :request do
  it 'answers without signing in' do
    allow(RenterInsight::PublicListings).to receive(:fetch).with('15914382')
      .and_return(listings: [{ id: '1', rent: 1400 }], property: { name: 'The James Apartments' })

    get '/public/rental_listings', params: { listing: '15914382' }

    expect(response).to have_http_status(:ok)
    body = JSON.parse(response.body)
    expect(body['listings'].first['rent']).to eq(1400)
    expect(body['available']).to be(true)
  end

  it 'gives an empty list, not an error, when the source is down' do
    allow(RenterInsight::PublicListings).to receive(:fetch).and_return(nil)

    get '/public/rental_listings', params: { listing: '15914382' }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to include('listings' => [], 'available' => false)
  end

  it 'rejects an unknown source or a malformed id' do
    get '/public/rental_listings', params: { listing: 'abc' }
    expect(response).to have_http_status(:bad_request)

    get '/public/rental_listings', params: { listing: '15914382', source: 'zillow' }
    expect(response).to have_http_status(:bad_request)
  end
end

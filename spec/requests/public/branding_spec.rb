# frozen_string_literal: true

require 'rails_helper'

# A dealer's website sends people to our sign-in, and a page wearing our logo
# reads as having been handed off to a stranger. This is the lookup that lets
# the sign-in look like the place the visitor just left.
RSpec.describe 'Public branding', type: :request do
  let(:company) { create(:company, name: 'Home + Design Studio') }

  it "returns the dealer's own identity" do
    get '/public/branding', params: { company_id: company.id }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body).dig('branding', 'name')).to eq('Home + Design Studio')
  end

  it 'needs no credential, since nobody is signed in yet' do
    get '/public/branding', params: { company_id: company.id }

    expect(response).to have_http_status(:ok)
  end

  # The sign-in page must render whatever happens here.
  it 'answers plainly for a company that does not exist' do
    get '/public/branding', params: { company_id: 0 }

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['branding']).to be_nil
  end

  it 'answers plainly when asked for nothing at all' do
    get '/public/branding'

    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)['branding']).to be_nil
  end

  # Deliberately narrow: this cannot become a way to read anything else.
  it 'returns only the name, logo and colour' do
    get '/public/branding', params: { company_id: company.id }

    expect(JSON.parse(response.body)['branding'].keys).to all(be_in(%w[name logo_url primary_color]))
  end
end

# frozen_string_literal: true

require 'rails_helper'

# The composer asks you to link "a vehicle", which is wrong for a manufactured
# housing dealer selling homes. The label system already answers this: the
# 'vehicle' key resolves to "Home" for that industry and a tenant can override
# it under Settings > Labels. The intent catalog only knows the broad family,
# so every dealer got the generic 'unit' and the composer rewrote it to
# "Vehicle", disagreeing with the label used everywhere else.
RSpec.describe 'Api::V1::SocialPosts intent_options subject label', type: :request do
  def company_with(industry)
    Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: industry)
  end

  def get_options(company)
    user = User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                        password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
    token = JsonWebToken.encode(user_id: user.id, company_id: company.id)
    get '/api/v1/social-posts/intent_options',
        headers: { 'Authorization' => "Bearer #{token}", 'Content-Type' => 'application/json' }
    JSON.parse(response.body)
  end

  it 'calls it a Home for a manufactured housing dealer' do
    body = get_options(company_with('manufactured_housing'))

    expect(body['subject_label']).to eq('Home')
  end

  it 'calls it a Unit for an RV dealer' do
    body = get_options(company_with('rv'))

    expect(body['subject_label']).to eq('Unit')
  end

  it 'follows a tenant override from Settings > Labels' do
    company = company_with('manufactured_housing')
    Setting.set('Company', company.id, 'label_overrides', { 'vehicle' => 'Cottage' })

    expect(get_options(company)['subject_label']).to eq('Cottage')
  end

  # Non-dealer families have no inventory behind the word, so the catalog's own
  # wording stands.
  it 'leaves a non-dealer industry on the catalog wording' do
    body = get_options(company_with('saas'))

    expect(body['subject_label']).not_to eq('Home')
    expect(body['family']).not_to eq('dealer')
  end
end

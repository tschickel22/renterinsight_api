# frozen_string_literal: true

require 'rails_helper'

# Facebook Lead Ads sends its questions verbatim, punctuation and all, while the
# custom field auto-created from that same question has the punctuation stripped.
# Exact-only matching missed over a lone "?" and dumped every answer into notes.
# Payloads below are the real ones captured from Evangeline Home Center's Zap.
RSpec.describe 'Api::Partner::V1 Leads custom field matching', type: :request do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:location) { Location.create!(company_id: company.id, name: 'Denver', code: 'DEN', active: true) }
  let(:creator) do
    User.create!(email: "c-#{SecureRandom.hex(4)}@example.com", first_name: 'C', last_name: 'R',
                 password: 'Pass1234!', company_id: company.id, role: 'platform_admin')
  end

  def make_key
    ApiKey.new(company_id: company.id, name: 'Facebook Leads — Evangeline Home Center',
               key: "ri_live_#{SecureRandom.hex(24)}",
               permissions: { 'leads' => %w[read create] }, status: 'active',
               created_by_user_id: creator.id,
               webhook_config: { default_location_id: location.id, dedupe_enabled: true })
          .tap { |k| k.save!(validate: false) }
  end

  def headers_for(key)
    { 'Authorization' => "Bearer #{key.key}", 'Content-Type' => 'application/json' }
  end

  # Company 17's real lead field_keys, including the renamed goal-timeframe key.
  FIELD_KEYS = %w[
    are_you_wanting_to_finance_or_buy_in_cash
    what_is_important_to_you_in_a_home_bedrooms_bath_special_features_hobbies_size
    tell_me_about_your_current_living_situation_own_or_renting
    tell_me_a_little_bit_about_your_shopping_experience_how_has_it_been_so_far
    what_don_t_you_like_about_where_you_live_now
    what_is_the_goal_time_frame_of_you_wanting_to_purchase_move
    what_are_you_currently_doing_for_work
  ].freeze

  before do
    FIELD_KEYS.each_with_index do |fk, i|
      CustomField.create!(company_id: company.id, module: 'leads', field_key: fk, name: fk,
                          label: fk.humanize, field_type: 'text', is_active: true, display_order: i)
    end
  end

  # Verbatim from prod request f46e0321 (lead 19470, RICHARD MATTES).
  def fb_answers
    {
      "are_you_wanting_to_finance_or_buy_in_cash?" => 'Finance',
      "what_is_important_to_you_in_a_home?_(bedrooms/bath/special_features/hobbies/size)" => 'bedroom',
      "tell_me_about_your_current_living_situation._(own_or_renting?)" => 'Own',
      "tell_me_a_little_bit_about_your_shopping_experience._(how_has_it_been_so_far?)" => 'Just started',
      "what_don't_you_like_about_where_you_live_now?" => 'Bad location',
      "what_is_the_goal_time_frame_of_you_wanting_to_purchase/move?" => '6+ months',
      "what_are_you_currently_doing_for_work?" => 'Retired'
    }
  end

  it 'maps every raw Facebook question onto its custom field with no Zap changes' do
    key = make_key
    payload = fb_answers.merge(
      'full_name' => 'RICHARD MATTES',
      'email' => 'richardrmm7@example.com',
      'phone' => '+18508612714',
      'raw' => fb_answers.merge('full_name' => 'RICHARD MATTES')
    )

    post '/api/partner/v1/leads', params: payload.to_json, headers: headers_for(key)
    expect(response).to have_http_status(:created)
    lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))

    expect(lead.custom_field_values).to include(
      'are_you_wanting_to_finance_or_buy_in_cash' => 'Finance',
      'what_is_important_to_you_in_a_home_bedrooms_bath_special_features_hobbies_size' => 'bedroom',
      'tell_me_about_your_current_living_situation_own_or_renting' => 'Own',
      'tell_me_a_little_bit_about_your_shopping_experience_how_has_it_been_so_far' => 'Just started',
      'what_don_t_you_like_about_where_you_live_now' => 'Bad location',
      'what_is_the_goal_time_frame_of_you_wanting_to_purchase_move' => '6+ months',
      'what_are_you_currently_doing_for_work' => 'Retired'
    )
    expect(lead.custom_field_values.keys).to match_array(FIELD_KEYS)
  end

  it 'leaves nothing for the notes fallback once every question matched' do
    key = make_key
    post '/api/partner/v1/leads',
         params: fb_answers.merge('full_name' => 'A B', 'email' => 'clean@example.com').to_json,
         headers: headers_for(key)
    lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))

    expect(lead.notes).to be_blank
    expect(Note.where(entity_type: 'lead', entity_id: lead.id.to_s)).to be_empty
  end

  it 'still routes genuinely unknown questions to notes' do
    key = make_key
    post '/api/partner/v1/leads',
         params: fb_answers.merge('full_name' => 'A B', 'email' => 'partial@example.com',
                                  'do_you_have_a_trade_in?' => 'Trading').to_json,
         headers: headers_for(key)
    lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))

    expect(lead.custom_field_values['are_you_wanting_to_finance_or_buy_in_cash']).to eq('Finance')
    note = Note.where(entity_type: 'lead', entity_id: lead.id.to_s).last
    expect(note.content).to include('Trading')
    expect(note.content).not_to include('Retired')
  end

  it 'maps on a repeat inquiry too, where answers arrive for an existing lead' do
    key = make_key
    email = 'repeat-cf@example.com'

    post '/api/partner/v1/leads',
         params: { full_name: 'RICHARD MATTES', email: email }.to_json, headers: headers_for(key)
    lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))
    expect(lead.custom_field_values).to be_blank

    post '/api/partner/v1/leads',
         params: fb_answers.merge('full_name' => 'RICHARD MATTES', 'email' => email).to_json,
         headers: headers_for(key)
    expect(response).to have_http_status(:accepted)

    expect(lead.reload.custom_field_values['what_are_you_currently_doing_for_work']).to eq('Retired')
    expect(lead.custom_field_values['what_is_the_goal_time_frame_of_you_wanting_to_purchase_move']).to eq('6+ months')
  end

  it 'finds answers that arrive only inside the raw passthrough blob' do
    key = make_key
    post '/api/partner/v1/leads',
         params: { full_name: 'A B', email: 'rawonly@example.com', raw: fb_answers }.to_json,
         headers: headers_for(key)
    lead = Lead.find(JSON.parse(response.body).dig('data', 'id'))

    expect(lead.custom_field_values['are_you_wanting_to_finance_or_buy_in_cash']).to eq('Finance')
  end
end

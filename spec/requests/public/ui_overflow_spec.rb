# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'POST /ui_overflow', type: :request do
  let(:payload) do
    { path: '/crm/leads/:id', viewport: 430, over: 42, tag: 'div',
      cls: 'flex items-center shrink-0' }
  end

  it 'accepts a report without auth and answers with nothing' do
    post '/ui_overflow', params: payload
    expect(response).to have_http_status(:no_content)
    expect(response.body).to be_blank
  end

  it 'writes one line naming the route and how far over it went' do
    allow(Rails.logger).to receive(:warn)

    post '/ui_overflow', params: payload

    expect(Rails.logger).to have_received(:warn).with(
      a_string_including('[UiOverflow]', 'path=/crm/leads/:id', 'vw=430', 'over=42px')
    )
  end

  it 'cannot be used to smuggle a wall of text into the logs' do
    allow(Rails.logger).to receive(:warn)

    post '/ui_overflow', params: payload.merge(cls: 'x' * 5_000)

    expect(Rails.logger).to have_received(:warn) do |line|
      expect(line.length).to be < 2_000
    end
  end

  it 'survives a malformed report rather than becoming the error' do
    post '/ui_overflow', params: { viewport: 'not-a-number' }
    expect(response).to have_http_status(:no_content)
  end
end

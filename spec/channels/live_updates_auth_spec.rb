# frozen_string_literal: true

require 'rails_helper'

# Live updates open only with a sign-in token, and each person hears only
# their own pop-ups. Until 2026-10-16 the connection trusted a user_id from
# the browser and fell back to the first user in the database.
RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:user) { User.create!(email: "c-#{SecureRandom.hex(4)}@example.com", password: 'Password123!', first_name: 'C', last_name: 'D', status: 'active') }

  it 'connects with a valid token as that person' do
    connect '/cable', params: { token: JsonWebToken.encode(user_id: user.id) }
    expect(connection.current_user).to eq(user)
  end

  it 'refuses no token, a bad token, or a bare user_id' do
    expect { connect '/cable' }.to have_rejected_connection
    expect { connect '/cable', params: { token: 'nope' } }.to have_rejected_connection
    expect { connect '/cable', params: { user_id: user.id } }.to have_rejected_connection
  end
end

RSpec.describe UserNotificationsChannel, type: :channel do
  let(:user) { User.create!(email: "n-#{SecureRandom.hex(4)}@example.com", password: 'Password123!', first_name: 'N', last_name: 'O', status: 'active') }

  it "streams the person's own pop-ups, whatever user_id is asked for" do
    stub_connection current_user: user
    subscribe user_id: user.id + 1
    expect(subscription).to be_confirmed
    expect(subscription).to have_stream_from("user_notifications_#{user.id}")
    expect(subscription).not_to have_stream_from("user_notifications_#{user.id + 1}")
  end
end

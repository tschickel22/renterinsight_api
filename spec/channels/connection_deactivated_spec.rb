# frozen_string_literal: true

require 'rails_helper'

RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:user) do
    User.create!(email: "c-#{SecureRandom.hex(4)}@example.com", first_name: 'C', last_name: 'A', password: 'Pass1234!',
                 company_id: create(:company).id, role: 'company_staff', status: 'active')
  end

  it 'connects an active user' do
    connect "/cable?token=#{JsonWebToken.generate_access_token(user)}"
    expect(connection.current_user).to eq(user)
  end

  it 'turns away a disabled user whose token is still good' do
    token = JsonWebToken.generate_access_token(user)
    user.update!(status: 'disabled')
    expect { connect "/cable?token=#{token}" }.to have_rejected_connection
  end
end

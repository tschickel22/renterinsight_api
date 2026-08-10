# frozen_string_literal: true

require 'rails_helper'

# The response to a reset request must not differ between a real account and an unknown
# address, or anyone can test addresses for membership. It also must not claim a delivery
# that did not happen: a GM whose account address had been changed under him read
# "Reset instructions sent successfully" on every attempt and waited on mail nobody sent.
RSpec.describe PasswordResetService, 'response for an unknown address' do
  let(:company) { Company.create!(name: "PR-#{SecureRandom.hex(4)}") }
  let!(:user) do
    User.create!(
      company: company, email: "real#{SecureRandom.hex(4)}@example.com",
      first_name: 'Real', last_name: 'User', password: 'Password123!', status: 'active'
    )
  end

  def request_for(email)
    described_class.new(ip_address: '127.0.0.1', user_agent: 'rspec')
                   .request_reset(email: email, phone: nil, delivery_method: 'email', user_type: 'auto')
  end

  before do
    allow_any_instance_of(described_class).to receive(:send_email_reset).and_return(true)
    allow_any_instance_of(described_class).to receive(:delivery_enabled?).and_return(true)
  end

  it 'answers an unknown address identically to a real one' do
    known   = request_for(user.email)
    unknown = request_for('nobody@example.com')

    expect(unknown[:message]).to eq(known[:message])
    expect(unknown[:success]).to eq(known[:success])
  end

  it 'states the condition rather than asserting a send' do
    result = request_for('nobody@example.com')

    expect(result[:message]).to eq(described_class::NEUTRAL_SENT_MESSAGE)
    expect(result[:message]).to match(/if an account exists/i)
    expect(result[:message]).not_to match(/sent successfully/i)
  end

  it 'creates no reset token for an address with no account' do
    expect { request_for('nobody@example.com') }.not_to change(PasswordResetToken, :count)
  end

  it 'still creates a token for a real account' do
    expect { request_for(user.email) }.to change(PasswordResetToken, :count).by(1)
  end

  # The point of the wording is that the reader can act on it. Confirming the address is the
  # only thing available to somebody whose account address was changed without them knowing.
  it 'tells the reader to check the address they used' do
    expect(described_class::NEUTRAL_SENT_MESSAGE).to match(/address/i)
  end
end

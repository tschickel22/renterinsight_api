# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Truebuild::Trueview::Credits do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let!(:admin) do
    User.create!(email: "pa-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'S', password: 'Pass1234!',
                 company_id: company.id, role: 'platform_admin')
  end
  let(:refused) do
    instance_double(HTTParty::Response, code: 402, body: '{}',
                                        parsed_response: { 'error' => { 'message' => 'Your prepayment credits are depleted.' } })
  end

  around do |ex|
    old = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ex.run
  ensure
    Rails.cache = old
  end

  it 'pauses drawing and tells the platform admins once when Gemini says the credits ran out' do
    expect { described_class.check!(refused) }.to raise_error(Truebuild::Trueview::Error, /402.*depleted/)
    expect(described_class.out?).to be(true)
    note = Notification.where(recipient: admin, notification_type: 'system_alert').sole
    expect(note.title).to include('Gemini credits ran out')
    expect(note.message).to include('Your prepayment credits are depleted.', 'Google AI Studio')

    expect { described_class.check!(refused) }.to raise_error(Truebuild::Trueview::Error)
    expect(Notification.where(recipient: admin).count).to eq(1) # not again within ALERT_EVERY
  end

  it 'leaves a good answer alone' do
    expect(described_class.check!(instance_double(HTTParty::Response, code: 200))).to be_nil
    expect(described_class.out?).to be(false)
  end

  it 'queues nothing for a buyer while paused' do
    Rails.cache.write(described_class::FLAG, true)
    buyer = Truebuild::Trueview::Buyer.allocate
    expect(buyer).not_to receive(:missing)
    expect(buyer.queue_missing!).to eq(0)
  end
end

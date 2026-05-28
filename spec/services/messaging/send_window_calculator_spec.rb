# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Messaging::SendWindowCalculator do
  let(:company) { Company.create!(name: 'Acme') }

  it 'returns :ok for SMS at 10am Pacific with no business hours' do
    recipient = Struct.new(:state).new('CA')
    now = Time.use_zone('Pacific Time (US & Canada)') { Time.zone.local(2026, 4, 27, 10, 0, 0) }
    out = described_class.new(send_window: {}, channel: 'sms', recipient: recipient, company: company, now: now).evaluate
    expect(out).to eq(:ok)
  end

  it 'returns next 8am for SMS sent during quiet hours (3am Pacific)' do
    recipient = Struct.new(:state).new('CA')
    now = Time.use_zone('Pacific Time (US & Canada)') { Time.zone.local(2026, 4, 27, 3, 0, 0) }
    out = described_class.new(send_window: {}, channel: 'sms', recipient: recipient, company: company, now: now).evaluate
    expect(out).to be_a(Time)
    expect(out.in_time_zone('Pacific Time (US & Canada)').hour).to eq(8)
  end

  it 'returns next-day 8am for SMS at 10pm recipient time' do
    recipient = Struct.new(:state).new('NY')
    now = Time.use_zone('Eastern Time (US & Canada)') { Time.zone.local(2026, 4, 27, 22, 0, 0) }
    out = described_class.new(send_window: {}, channel: 'sms', recipient: recipient, company: company, now: now).evaluate
    expect(out).to be_a(Time)
    expect(out.in_time_zone('Eastern Time (US & Canada)').day).to eq(28)
  end

  it 'enforces business_hours_only window for email' do
    recipient = Struct.new(:state).new('NY')
    now = Time.use_zone('Eastern Time (US & Canada)') { Time.zone.local(2026, 4, 27, 7, 0, 0) }
    out = described_class.new(
      send_window: { 'business_hours_only' => true, 'start_hour' => 9, 'end_hour' => 17 },
      channel: 'email', recipient: recipient, company: company, now: now
    ).evaluate
    expect(out).to be_a(Time)
    expect(out.in_time_zone('Eastern Time (US & Canada)').hour).to eq(9)
  end

  it 'skips weekends when configured' do
    recipient = Struct.new(:state).new('NY')
    saturday = Time.use_zone('Eastern Time (US & Canada)') { Time.zone.local(2026, 4, 25, 10, 0, 0) }  # Sat
    out = described_class.new(
      send_window: { 'business_hours_only' => true, 'skip_weekends' => true, 'start_hour' => 9, 'end_hour' => 17 },
      channel: 'email', recipient: recipient, company: company, now: saturday
    ).evaluate
    expect(out).to be_a(Time)
    expect(out.in_time_zone('Eastern Time (US & Canada)').wday).to eq(1)  # Monday
  end

  it 'falls back to Eastern when no recipient state' do
    recipient = Struct.new(:state).new(nil)
    nogo = Time.use_zone('Eastern Time (US & Canada)') { Time.zone.local(2026, 4, 27, 4, 0, 0) }
    out = described_class.new(send_window: {}, channel: 'sms', recipient: recipient, company: nil, now: nogo).evaluate
    expect(out).to be_a(Time)
  end

  it 'uses the company timezone when the recipient has no state' do
    Setting.set('Company', company.id, 'operational', { 'timezone' => 'America/Denver' })
    recipient = Struct.new(:state).new(nil)
    # 8:00 AM Mountain is before the 9 AM window. If it (wrongly) used Eastern, local time
    # would be 10 AM — inside the window — and it would return :ok instead of a deferral.
    now = Time.use_zone('America/Denver') { Time.zone.local(2026, 4, 27, 8, 0, 0) }
    out = described_class.new(
      send_window: { 'business_hours_only' => true, 'start_hour' => 9, 'end_hour' => 17 },
      channel: 'email', recipient: recipient, company: company, now: now
    ).evaluate
    expect(out).to be_a(Time)
    expect(out.in_time_zone('America/Denver').hour).to eq(9)
  end
end

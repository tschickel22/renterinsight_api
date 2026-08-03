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
    # 'operational_settings' is the key the Company Settings UI writes (CompanySettingsController)
    Setting.set('Company', company.id, 'operational_settings', { 'timezone' => 'America/Denver' })
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

  # Older campaigns store the window as hour_start/hour_end/days/timezone. Nothing read those
  # keys, so seven live production campaigns had no window at all while their settings screen
  # showed weekdays nine to four.
  describe 'legacy hour_start/hour_end/days/timezone shape' do
    let(:recipient) { Struct.new(:state).new('NY') }
    let(:window) do
      { 'days' => %w[mon tue wed thu], 'hour_start' => 9, 'hour_end' => 16, 'timezone' => 'America/Chicago' }
    end

    def evaluate_at(now, send_window: window, channel: 'email')
      described_class.new(send_window: send_window, channel: channel, recipient: recipient,
                          company: company, now: now).evaluate
    end

    it 'sends inside the window' do
      now = Time.use_zone('America/Chicago') { Time.zone.local(2026, 8, 3, 10, 0, 0) } # Monday
      expect(evaluate_at(now)).to eq(:ok)
    end

    # The case that shipped: 22:11 UTC on a Monday is 17:11 Central, past hour_end.
    it 'defers a send past hour_end to the next allowed morning' do
      now = Time.utc(2026, 8, 3, 22, 11)
      out = evaluate_at(now)

      expect(out).to be_a(Time)
      local = out.in_time_zone('America/Chicago')
      expect(local.hour).to eq(9)
      expect(local.day).to eq(4) # Tuesday
    end

    # The window's own timezone wins over the recipient's. 8:30 Central is before the window;
    # read as Eastern it would be 9:30 and wrongly allowed.
    it 'evaluates hours in the window timezone, not the recipient timezone' do
      now = Time.use_zone('America/Chicago') { Time.zone.local(2026, 8, 3, 8, 30, 0) }
      out = evaluate_at(now)

      expect(out).to be_a(Time)
      expect(out.in_time_zone('America/Chicago').hour).to eq(9)
    end

    it 'skips days that are not in the list' do
      friday = Time.use_zone('America/Chicago') { Time.zone.local(2026, 8, 7, 10, 0, 0) }
      out = evaluate_at(friday)

      expect(out).to be_a(Time)
      expect(out.in_time_zone('America/Chicago').wday).to eq(1) # Monday
    end

    it 'accepts full day names as well as abbreviations' do
      sunday = Time.use_zone('America/Chicago') { Time.zone.local(2026, 8, 2, 10, 0, 0) }
      out = evaluate_at(sunday, send_window: window.merge('days' => %w[Monday Tuesday]))

      expect(out.in_time_zone('America/Chicago').wday).to eq(1)
    end

    it 'ignores a timezone Rails does not recognise rather than raising' do
      now = Time.use_zone('America/Chicago') { Time.zone.local(2026, 8, 3, 10, 0, 0) }
      expect { evaluate_at(now, send_window: window.merge('timezone' => 'Mars/Olympus')) }.not_to raise_error
    end

    # A day list nobody can parse would otherwise match no day and defer the enrollment
    # forever, one day at a time.
    it 'treats an unparseable day list as no restriction' do
      now = Time.use_zone('America/Chicago') { Time.zone.local(2026, 8, 2, 10, 0, 0) } # Sunday
      expect(evaluate_at(now, send_window: window.merge('days' => %w[funday]))).to eq(:ok)
    end

    # Same trap from the other direction: hours that cannot both be satisfied.
    it 'ignores hours that end before they start' do
      now = Time.use_zone('America/Chicago') { Time.zone.local(2026, 8, 3, 20, 0, 0) }
      out = evaluate_at(now, send_window: { 'hour_start' => 17, 'hour_end' => 9 })

      expect(out).to eq(:ok)
    end

    it 'leaves TCPA on the recipient clock even when the window names another timezone' do
      # 22:30 Eastern is inside 9-16 Central by the clock the window names, but it is still
      # after 9pm where the recipient lives.
      now = Time.use_zone('Eastern Time (US & Canada)') { Time.zone.local(2026, 8, 3, 22, 30, 0) }
      out = evaluate_at(now, send_window: window.merge('hour_end' => 23), channel: 'sms')

      expect(out).to be_a(Time)
      expect(out.in_time_zone('Eastern Time (US & Canada)').hour).to eq(8)
    end
  end

  describe 'business_hours_only explicitly off' do
    # The toggle writes false but leaves the hours behind. Honouring those hours would
    # enforce a window the tenant just turned off.
    it 'does not enforce hours left over in the row' do
      recipient = Struct.new(:state).new('NY')
      now = Time.use_zone('Eastern Time (US & Canada)') { Time.zone.local(2026, 8, 3, 6, 0, 0) }
      out = described_class.new(
        send_window: { 'business_hours_only' => false, 'start_hour' => 9, 'end_hour' => 17 },
        channel: 'email', recipient: recipient, company: company, now: now
      ).evaluate

      expect(out).to eq(:ok)
    end
  end
end

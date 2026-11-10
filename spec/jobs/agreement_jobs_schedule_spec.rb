# frozen_string_literal: true

require 'rails_helper'

# Neither agreement job was in the recurring schedule, so agreements never
# expired and no automatic reminder went out.
RSpec.describe 'Agreement jobs schedule' do
  let(:config) { YAML.safe_load(Rails.root.join('config/recurring.yml').read, aliases: true) }

  %w[production staging].each do |env|
    it "schedules expiry hourly and reminders daily in #{env}" do
      tasks = config.fetch(env)
      expiry = tasks.values.find { |t| t['class'] == 'ExpireAgreementsJob' }
      reminders = tasks.values.find { |t| t['class'] == 'AgreementReminderJob' }

      expect(expiry).to be_present
      expect(reminders).to be_present
      expect(Fugit.parse(expiry['schedule'])).to be_a(Fugit::Cron)
      expect(Fugit.parse(reminders['schedule'])).to be_a(Fugit::Cron)
      expect(Fugit.parse(reminders['schedule']).timezone&.name).to eq('America/Denver')
    end
  end

  it 'expires a past-due agreement and fires agreement.expired' do
    company = Company.create!(name: "Expiry Co #{SecureRandom.hex(3)}")
    agreement = company.agreements.create!(title: 'Purchase', status: 'sent', sent_at: 10.days.ago)
    agreement.update_columns(expires_at: 1.hour.ago)
    still_open = company.agreements.create!(title: 'Later', status: 'sent', sent_at: 1.day.ago, expires_at: 5.days.from_now)
    allow(WebhookService).to receive(:fire)

    ExpireAgreementsJob.perform_now

    expect(agreement.reload.status).to eq('expired')
    expect(still_open.reload.status).to eq('sent')
    expect(WebhookService).to have_received(:fire)
      .with(hash_including(company_id: company.id, event: 'agreement.expired')).once
  end

  it 'offers agreement.expired in the webhook picker' do
    expect(WebhookEndpoint.available_events.map { |e| e[:value] }).to include('agreement.expired')
  end
end

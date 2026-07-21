# frozen_string_literal: true

require 'rails_helper'

RSpec.describe SendActivityRemindersJob, type: :job do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }
  let(:user) do
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: 'sales_rep')
  end
  let(:lead) { Lead.create!(company_id: company.id, first_name: 'A', last_name: 'A', email: 'a@x.com') }

  def make_reminder(offset:)
    LeadActivity.create!(
      lead_id: lead.id, user_id: user.id, assigned_to_id: user.id,
      activity_type: 'reminder', subject: 'Ping',
      reminder_time: Time.current + offset, reminder_sent: false,
      priority: 'medium', status: 'pending'
    )
  end

  before do
    allow(ActivityReminderService).to receive(:send_reminder).and_return(true)
    # Bypass the LeadActivity after_create :schedule_reminders callback so
    # we're testing the JOB's filter, not the model callback that fires
    # past-due reminders on save. Restored in after block.
    LeadActivity.skip_callback(:create, :after, :schedule_reminders)
  end

  after { LeadActivity.set_callback(:create, :after, :schedule_reminders, if: -> { ['reminder', 'call', 'task', 'meeting'].include?(activity_type) && reminder_time.present? }) }

  it 'sends an upcoming reminder inside the 5-minute lookahead' do
    r = make_reminder(offset: 2.minutes)
    described_class.new.perform
    expect(ActivityReminderService).to have_received(:send_reminder).with(having_attributes(id: r.id))
  end

  it 'sends a past-due reminder if it is within 24 hours' do
    r = make_reminder(offset: -1.hour)
    described_class.new.perform
    expect(ActivityReminderService).to have_received(:send_reminder).with(having_attributes(id: r.id))
  end

  it 'skips ancient past-due reminders (>24h) so an outage burst does not spam' do
    make_reminder(offset: -25.hours)
    described_class.new.perform
    expect(ActivityReminderService).not_to have_received(:send_reminder)
  end

  it 'skips reminders further than the lookahead window' do
    make_reminder(offset: 10.minutes)
    described_class.new.perform
    expect(ActivityReminderService).not_to have_received(:send_reminder)
  end

  it 'does not re-send a reminder that already fired' do
    make_reminder(offset: -30.minutes).update!(reminder_sent: true)
    described_class.new.perform
    expect(ActivityReminderService).not_to have_received(:send_reminder)
  end
end

# frozen_string_literal: true

require 'rails_helper'

RSpec.describe GenerateScheduledSocialPostsJob do
  let(:company) { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:schedule) do
    SocialPostSchedule.create!(
      company_id: company.id, frequency: 'weekly', require_vehicle: false,
      intent_rotation: ['feature_spotlight'],
      intent_notes: { 'feature_spotlight' => 'Highlight the new analytics dashboard' }
    )
  end

  # Drive generate_for with a controlled intent, stubbing the post-build/reschedule tail
  # so we can assert what topic_details the generator receives.
  def run(intent:)
    allow(ScheduleIntentPicker).to receive(:next).and_return(intent)
    allow(SchedulePreviewVehiclePicker).to receive(:pick).and_return(nil)
    job = described_class.new
    post = instance_double('SocialPost', save!: true, update_columns: true, id: 1)
    allow(job).to receive(:build_post_from_result).and_return(post)
    allow(job).to receive(:build_tagged_url).and_return('https://example.com')
    allow(job).to receive(:send_approval_email)
    allow(job).to receive(:reschedule)
    job.send(:generate_for, schedule)
  end

  it "passes the user's per-intent note as topic_details" do
    expect(SocialPostGeneratorService).to receive(:generate)
      .with(hash_including(topic_details: 'Highlight the new analytics dashboard'))
      .and_return({})
    run(intent: 'feature_spotlight')
  end

  it 'passes nil topic_details when there is no note and the intent is not seasonal' do
    schedule.update!(intent_notes: {})
    expect(SocialPostGeneratorService).to receive(:generate)
      .with(hash_including(topic_details: nil))
      .and_return({})
    run(intent: 'feature_spotlight')
  end

  it 'falls back to the seasonal auto-topic when there is no note and the intent is seasonal' do
    schedule.update!(intent_notes: {})
    allow(SeasonalContentService).to receive(:topic_for_seasonal_post).and_return('Spring savings event')
    expect(SocialPostGeneratorService).to receive(:generate)
      .with(hash_including(topic_details: 'Spring savings event'))
      .and_return({})
    run(intent: 'seasonal')
  end

  it 'prefers the user note over the seasonal auto-topic' do
    schedule.update!(intent_notes: { 'seasonal' => 'Talk about our spring open house' })
    expect(SeasonalContentService).not_to receive(:topic_for_seasonal_post)
    expect(SocialPostGeneratorService).to receive(:generate)
      .with(hash_including(topic_details: 'Talk about our spring open house'))
      .and_return({})
    run(intent: 'seasonal')
  end
end

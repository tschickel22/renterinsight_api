# frozen_string_literal: true

require 'rails_helper'

RSpec.describe PurgeStaleSocialDraftsJob do
  let(:company)  { Company.create!(name: "C-#{SecureRandom.hex(4)}") }
  let(:schedule) { company.social_post_schedules.create!(frequency: 'weekly', draft_retention_days: 7) }

  def post(status: 'draft', age_days: 30, schedule_id: schedule.id, **attrs)
    p = company.social_posts.create!(
      platform: 'facebook', post_type: 'company_page', status: status,
      caption: 'x',
      generation_context: schedule_id ? { 'schedule_id' => schedule_id } : {},
      **attrs
    )
    p.update_column(:created_at, age_days.days.ago)
    p
  end

  def expired?(record) = record.reload.is_deleted == true

  it 'expires an auto-generated draft past the retention window' do
    stale = post(age_days: 30)
    described_class.new.perform
    expect(expired?(stale)).to be(true)
  end

  it 'keeps a draft still inside the window' do
    fresh = post(age_days: 2)
    described_class.new.perform
    expect(expired?(fresh)).to be(false)
  end

  it 'never touches a hand-written draft, however old' do
    manual = post(age_days: 90, schedule_id: nil)
    described_class.new.perform
    expect(expired?(manual)).to be(false)
  end

  %w[approved scheduled published failed].each do |status|
    it "never expires a #{status} post" do
      kept = post(status: status, age_days: 90)
      described_class.new.perform
      expect(expired?(kept)).to be(false)
    end
  end

  it 'treats 0 as expiry disabled' do
    schedule.update!(draft_retention_days: 0)
    kept = post(age_days: 365)
    described_class.new.perform
    expect(expired?(kept)).to be(false)
  end

  it 'honors a per-schedule window rather than a global one' do
    short = company.social_post_schedules.create!(frequency: 'weekly', draft_retention_days: 1)
    long  = company.social_post_schedules.create!(frequency: 'weekly', draft_retention_days: 90)

    short_draft = post(age_days: 5, schedule_id: short.id)
    long_draft  = post(age_days: 5, schedule_id: long.id)

    described_class.new.perform

    expect(expired?(short_draft)).to be(true)
    expect(expired?(long_draft)).to be(false)
  end

  it 'leaves another company\'s drafts alone' do
    other = Company.create!(name: "O-#{SecureRandom.hex(4)}")
    other_schedule = other.social_post_schedules.create!(frequency: 'weekly', draft_retention_days: 7)
    theirs = other.social_posts.create!(
      platform: 'facebook', post_type: 'company_page', status: 'draft', caption: 'x',
      generation_context: { 'schedule_id' => schedule.id } # deliberately our schedule id
    )
    theirs.update_column(:created_at, 30.days.ago)

    described_class.new.perform

    # Scoped by company_id, so our schedule can't reach across the tenant line.
    expect(theirs.reload.is_deleted).to be_falsey
    expect(other_schedule).to be_present
  end

  it 'matches a schedule_id stored as a string on older rows' do
    stale = post(age_days: 30, schedule_id: schedule.id.to_s)
    described_class.new.perform
    expect(expired?(stale)).to be(true)
  end

  it 'reports how many it expired' do
    3.times { post(age_days: 30) }
    expect(described_class.new.perform).to eq(3)
  end
end

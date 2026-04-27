# frozen_string_literal: true

require 'rails_helper'

RSpec.describe CampaignGoalCheckJob do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:user)    { User.create!(email: "u-#{SecureRandom.hex(3)}@example.com", first_name: 'T', last_name: 'U', password: 'Pass1234!', company_id: company.id) }

  it 'invokes GoalChecker for each running campaign' do
    Campaign.create!(company_id: company.id, created_by_user_id: user.id, name: 'C',
                     campaign_type: 'blast', from_identity_type: 'User', from_identity_id: user.id,
                     throttle_per_day: 100, status: 'running', goal_config: { 'primary_goal' => 'opened' })
    checker = instance_double(Campaigns::GoalChecker, run: 0)
    allow(Campaigns::GoalChecker).to receive(:new).and_return(checker)
    described_class.perform_now
    expect(checker).to have_received(:run)
  end
end

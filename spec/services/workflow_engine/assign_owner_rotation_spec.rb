# frozen_string_literal: true

require 'rails_helper'

# Covers the 'round_robin' and 'load_balanced' strategies on AssignOwner.
#
# Both previously shared one implementation — min_by lifetime owned-record count
# — so 'round_robin' never rotated, and a rep's career total could never come
# back down, which pinned every new lead on whoever had the fewest records ever.
# The pool was also the raw company.users list: deactivated reps were eligible,
# and a role_filter matching nobody silently fell back to the whole company.
RSpec.describe WorkflowEngine::StepExecutors::AssignOwner, type: :service do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(4)}", industry: 'manufactured_housing') }

  def make_user(status: 'active', role: 'sales_rep')
    User.create!(email: "u-#{SecureRandom.hex(4)}@example.com", first_name: 'T', last_name: 'U',
                 password: 'Pass1234!', company_id: company.id, role: role, status: status)
  end

  def make_lead(owner: nil, created_at: nil)
    lead = Lead.create!(company_id: company.id, first_name: 'L', last_name: SecureRandom.hex(3),
                        owner_id: owner&.id)
    lead.update_column(:created_at, created_at) if created_at
    lead
  end

  def assign(lead, config)
    rule = WorkflowRule.create!(
      company: company, name: 'r', entity_type: 'Lead', status: 'active',
      trigger: {}, conditions: [], steps: { 'nodes' => [] }
    )
    run = WorkflowRun.create!(
      company: company, workflow_rule: rule, entity_type: 'Lead', entity_id: lead.id,
      status: 'running', current_step_id: 'step_1', started_at: Time.current, rule_snapshot: rule.steps
    )
    step = { 'id' => 'step_1', 'type' => 'assign_owner', 'config' => config }
    result = described_class.new(run: run, step: step).call
    [lead.reload, result]
  end

  describe 'round_robin' do
    it 'rotates across the pool instead of repeatedly picking the same user' do
      u1 = make_user
      u2 = make_user
      u3 = make_user

      picked = 3.times.map do
        lead, = assign(make_lead, 'strategy' => 'round_robin')
        lead.owner_id
      end

      expect(picked.uniq).to match_array([u1.id, u2.id, u3.id])
    end

    it 'picks the least-recently-assigned user, not the one with the fewest records' do
      veteran = make_user
      newcomer = make_user

      # Veteran has far more leads, but none recent. Newcomer has one, just now.
      5.times { make_lead(owner: veteran, created_at: 60.days.ago) }
      make_lead(owner: newcomer, created_at: 1.minute.ago)

      lead, = assign(make_lead, 'strategy' => 'round_robin')

      # Old behavior would pick `newcomer` (1 record < 5). Rotation picks the
      # veteran, who has been waiting longest.
      expect(lead.owner_id).to eq(veteran.id)
    end
  end

  describe 'load_balanced' do
    it 'counts only the trailing window, so historical volume does not disqualify a rep' do
      veteran = make_user
      newcomer = make_user

      10.times { make_lead(owner: veteran, created_at: 90.days.ago) }
      3.times  { make_lead(owner: newcomer, created_at: 2.days.ago) }

      lead, = assign(make_lead, 'strategy' => 'load_balanced')

      # Lifetime counts: veteran 10 vs newcomer 3 -> newcomer.
      # Trailing 30d:    veteran 0  vs newcomer 3 -> veteran.
      expect(lead.owner_id).to eq(veteran.id)
    end
  end

  describe 'pool eligibility' do
    it 'never assigns to a deactivated user' do
      active = make_user
      make_user(status: 'inactive')

      5.times do
        lead, = assign(make_lead, 'strategy' => 'round_robin')
        expect(lead.owner_id).to eq(active.id)
      end
    end

    it 'leaves the record unassigned when role_filter matches nobody' do
      make_user(role: 'sales_rep')

      lead, result = assign(make_lead, 'strategy' => 'round_robin', 'role_filter' => 'no_such_role')

      expect(lead.owner_id).to be_nil
      expect(result[:status]).to eq('skipped')
      expect(result[:output][:reason]).to eq('no_eligible_users')
    end

    it 'honors a role_filter that does match' do
      make_user(role: 'sales_rep')
      manager = make_user(role: 'company_manager')

      lead, = assign(make_lead, 'strategy' => 'round_robin', 'role_filter' => 'company_manager')

      expect(lead.owner_id).to eq(manager.id)
    end
  end
end

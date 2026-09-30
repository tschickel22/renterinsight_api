# frozen_string_literal: true

require 'rails_helper'

# Buyers who designed and saved a home on the website this week.
RSpec.describe 'Designed a Home work queue', type: :model do
  let(:company) { create(:company, use_rbac_system: false) }
  let(:user) do
    User.create!(email: "wqd-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Reid', last_name: 'Tester', role: 'admin')
  end
  let(:other_rep) do
    User.create!(email: "wqd-#{SecureRandom.hex(4)}@example.com", password: 'Password123!',
                 company: company, first_name: 'Ona', last_name: 'Other')
  end
  let(:mfr) { Manufacturer.create!(name: "Champion #{SecureRandom.hex(3)}", industry_type: 'manufactured_home') }
  let(:plan) { CatalogPlan.create!(manufacturer: mfr, series: 'Aspire', name: 'Belvidere') }
  let(:variant) { CatalogPlanVariant.create!(catalog_plan: plan, manufacturer: mfr, model_number: '2856H32392') }

  def designed(lead, at: Time.current)
    company.truebuild_designs.create!(variant: variant, lead: lead, name: 'Belvidere', created_at: at)
  end

  def service = WorkqueueService.new(company: company, user: user, queue_id: 'leads_designed_home')

  it "lists this week's designers, mine and unassigned, not another rep's or last month's" do
    mine = create(:lead, company: company, owner_id: user.id).tap { |l| designed(l) }
    unassigned = create(:lead, company: company, owner_id: nil).tap { |l| designed(l) }
    theirs = create(:lead, company: company, owner_id: other_rep.id).tap { |l| designed(l) }
    old = create(:lead, company: company, owner_id: user.id).tap { |l| designed(l, at: 20.days.ago) }

    ids = service.items[:items].map { |r| r[:entity_id] }
    expect(ids).to include(mine.id, unassigned.id)
    expect(ids).not_to include(theirs.id, old.id)
  end

  # Checked on the rule itself: the full summary also counts the activity
  # queues, which read a database view the test schema does not load.
  it 'only appears for dealers who use TrueBuild' do
    expect(service.send(:hidden_queue?, 'leads_designed_home')).to be(true)

    company.dealer_markup_rules.create!(scope_type: 'all', markup_type: 'percent', value: 25)
    expect(WorkqueueService.new(company: company, user: user).send(:hidden_queue?, 'leads_designed_home')).to be(false)
  end
end

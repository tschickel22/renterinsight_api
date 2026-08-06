# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marketing::IdentifyVisitor do
  let(:company) { Company.create!(name: "Id-#{SecureRandom.hex(4)}") }
  let(:site) { Marketing::MarketingSiteProvisioner.call(company: company) }
  let(:page) { site.website_pages.create!(title: 'Spring Sale', path: '/spring-sale', page_kind: 'landing') }
  let(:source) { Source.find_or_create_by!(name: 'Web') { |s| s.source_type = 'web' } }
  let(:lead) do
    Lead.create!(company: company, source: source, first_name: 'B', last_name: 'One',
                 email: "b-#{SecureRandom.hex(4)}@example.com")
  end

  def visit(token: 'v-1', session: SecureRandom.hex(4), at: Time.current, page_record: page)
    PageVisit.create!(
      company_id: company.id, website_page_id: page_record.id,
      visitor_token: token, session_token: session,
      first_seen_at: at, last_seen_at: at
    )
  end

  def identify(token: 'v-1', entity: lead, **opts)
    described_class.new(company: company, visitor_token: token, entity: entity, **opts).call
  end

  # The whole point: a visitor browses anonymously and only becomes a name when
  # they submit. Attributing just the final page throws away everything that
  # explains the conversion.
  it 'back-stamps every earlier anonymous visit from the same browser' do
    a = visit(at: 3.days.ago)
    b = visit(at: 1.day.ago)
    c = visit

    result = identify

    expect(result.visits_identified).to eq(3)
    expect([a, b, c].map { |v| v.reload.identified_entity }).to all(eq(lead))
    expect(a.reload.identified_at).to be_present
  end

  it 'claims visits across different landing pages' do
    other_page = site.website_pages.create!(title: 'Autumn', path: '/autumn', page_kind: 'landing')
    visit
    visit(page_record: other_page)

    expect(identify.visits_identified).to eq(2)
  end

  it 'ignores visits from a different browser' do
    mine = visit(token: 'v-1')
    theirs = visit(token: 'v-2')

    identify(token: 'v-1')

    expect(mine.reload.identified_entity).to eq(lead)
    expect(theirs.reload.identified_entity).to be_nil
  end

  # Two people sharing a browser is rarer than a re-submitted form, and
  # reassigning the first person's session is worse than missing it.
  it 'does not steal a visit already attributed to someone else' do
    other = Lead.create!(company: company, source: source, first_name: 'C', last_name: 'Two',
                         email: "c-#{SecureRandom.hex(4)}@example.com")
    claimed = visit
    claimed.identify!(other)

    result = identify

    expect(result.visits_identified).to eq(0)
    expect(claimed.reload.identified_entity).to eq(other)
  end

  it 'is idempotent' do
    visit
    first = identify.visits_identified
    second = identify.visits_identified

    expect(first).to eq(1)
    expect(second).to eq(0)
  end

  describe 'the attribution window' do
    it 'ignores visits older than the window' do
      old = visit(at: 90.days.ago)
      recent = visit(at: 2.days.ago)

      identify

      expect(old.reload.identified_entity).to be_nil
      expect(recent.reload.identified_entity).to eq(lead)
    end

    it 'accepts an explicit window' do
      old = visit(at: 90.days.ago)
      identify(window_days: 120)

      expect(old.reload.identified_entity).to eq(lead)
    end

    # Tunable without a deploy, matching the campaign plan's recommendation.
    it 'reads the window from platform settings when present' do
      allow(Setting).to receive(:get).with('Platform', 0, 'marketing')
                                     .and_return('attribution_window_days' => 120)
      old = visit(at: 90.days.ago)
      identify

      expect(old.reload.identified_entity).to eq(lead)
    end

    it 'falls back to the default when the setting is unreadable' do
      allow(Setting).to receive(:get).and_raise(StandardError, 'boom')
      recent = visit(at: 2.days.ago)
      identify

      expect(recent.reload.identified_entity).to eq(lead)
    end
  end

  describe 'safety' do
    it 'does nothing without a token or entity' do
      visit
      expect(identify(token: '').visits_identified).to eq(0)
      expect(identify(entity: nil).visits_identified).to eq(0)
    end

    # Attribution is enrichment. A lead captured but unattributed is a
    # reporting gap; an exception here would cost the lead.
    it 'never raises when the query fails' do
      allow(PageVisit).to receive(:where).and_raise(StandardError, 'db down')
      expect { identify }.not_to raise_error
      expect(identify.visits_identified).to eq(0)
    end
  end

  describe 'through an intake submission' do
    let(:form) { IntakeForm.create!(company_id: company.id, name: 'LP Form', is_active: true) }

    it 'attributes the session when the form carries the visitor token' do
      earlier = visit(at: 2.hours.ago)

      submission = IntakeSubmission.create!(
        intake_form: form,
        data: {
          'first_name' => 'Dana', 'last_name' => 'Reed',
          'email' => "dana-#{SecureRandom.hex(4)}@example.com",
          'visitor_token' => 'v-1'
        }
      )

      expect(submission.resolved_entity).to be_present
      expect(earlier.reload.identified_entity).to eq(submission.resolved_entity)
    end

    it 'does nothing when the form carries no visitor token' do
      earlier = visit(at: 2.hours.ago)

      IntakeSubmission.create!(
        intake_form: form,
        data: { 'first_name' => 'Dana', 'email' => "d-#{SecureRandom.hex(4)}@example.com" }
      )

      expect(earlier.reload.identified_entity).to be_nil
    end
  end
end

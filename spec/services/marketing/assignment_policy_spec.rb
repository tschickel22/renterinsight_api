# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Marketing::AssignmentPolicy do
  let(:company) { Company.create!(name: "Co-#{SecureRandom.hex(3)}") }
  let(:location) { company.locations.create!(name: 'Showroom') }

  # status: active on purpose. RoundRobinAssignmentList#next_active_user! skips
  # anyone who is not, which is correct and which a pending fixture hides.
  def rep(email:, booking: nil)
    company.users.create!(email: email, first_name: 'A', last_name: 'B',
                          password: SecureRandom.hex(8), booking_url: booking,
                          status: 'active')
  end

  def set_policy(scope, id, config, key: 'operational_settings')
    Setting.set(scope, id, key, { 'booking_assignment' => config })
  end

  describe 'the default' do
    # Nothing configured has to mean something predictable, and one dealership
    # calendar is the answer a dealer who has never thought about it expects.
    it 'is the dealership, not whoever happens to be assigned' do
      resolution = described_class.new(company: company).resolve(fallback_user: rep(email: "a#{SecureRandom.hex(3)}@t.test"))

      expect(resolution.mode).to eq('dealership')
      expect(resolution.user).to be_nil
    end

    it 'ignores a mode it does not recognise rather than failing' do
      set_policy('Company', company.id, { 'mode' => 'whatever' })

      expect(described_class.new(company: company).mode).to eq('dealership')
    end
  end

  describe 'a named person' do
    it 'resolves to exactly that person' do
      chosen = rep(email: "chosen#{SecureRandom.hex(3)}@t.test", booking: 'calendly.com/chosen')
      other = rep(email: "other#{SecureRandom.hex(3)}@t.test")
      set_policy('Company', company.id, { 'mode' => 'user', 'user_id' => chosen.id })

      expect(described_class.new(company: company).resolve(fallback_user: other).user).to eq(chosen)
    end

    # Scoped through the company, so a stale or hostile id cannot pull in
    # someone from another dealer.
    it 'will not resolve a user from another company' do
      outsider = Company.create!(name: 'Other Co').users.create!(
        email: "out#{SecureRandom.hex(3)}@t.test", first_name: 'X', last_name: 'Y',
        password: SecureRandom.hex(8)
      )
      set_policy('Company', company.id, { 'mode' => 'user', 'user_id' => outsider.id })

      expect(described_class.new(company: company).resolve.user).to be_nil
    end
  end

  describe 'a set of people' do
    it 'rotates across the list' do
      one = rep(email: "one#{SecureRandom.hex(3)}@t.test")
      two = rep(email: "two#{SecureRandom.hex(3)}@t.test")
      list = RoundRobinAssignmentList.create!(company_id: company.id, name: 'Sales',
                                              user_ids: [one.id, two.id], active: true)
      set_policy('Company', company.id, { 'mode' => 'round_robin', 'round_robin_list_id' => list.id })

      policy = described_class.new(company: company)
      picked = [policy.resolve.user, described_class.new(company: company).resolve.user]

      expect(picked.compact.map(&:id)).to all(be_in([one.id, two.id]))
      expect(picked.compact.size).to eq(2)
    end

    it 'falls back to nobody rather than raising when the list is gone' do
      set_policy('Company', company.id, { 'mode' => 'round_robin', 'round_robin_list_id' => 999_999 })

      expect(described_class.new(company: company).resolve.user).to be_nil
    end
  end

  describe 'whoever owns the relationship' do
    it 'uses the assigned rep when the dealer asked for that' do
      owner = rep(email: "own#{SecureRandom.hex(3)}@t.test")
      set_policy('Company', company.id, { 'mode' => 'assigned_rep' })

      expect(described_class.new(company: company).resolve(fallback_user: owner).user).to eq(owner)
    end
  end

  # A multi-lot dealer routinely runs one lot differently from another.
  describe 'per location' do
    it 'lets a location override the company' do
      set_policy('Company', company.id, { 'mode' => 'dealership' })
      set_policy('Location', location.id, { 'mode' => 'assigned_rep' }, key: 'operational')
      owner = rep(email: "loc#{SecureRandom.hex(3)}@t.test")

      resolution = described_class.new(company: company, location: location).resolve(fallback_user: owner)

      expect(resolution.mode).to eq('assigned_rep')
      expect(resolution.user).to eq(owner)
    end

    # The settings UI writes one key at the location scope and
    # LocationSettingsResolver reads the other, so both are read here.
    it 'reads a location policy under either key spelling' do
      set_policy('Location', location.id, { 'mode' => 'assigned_rep' }, key: 'operational_settings')

      expect(described_class.new(company: company, location: location).mode).to eq('assigned_rep')
    end
  end

  describe 'what the booking link does with it' do
    before { Setting.set('Company', company.id, 'operational_settings', { 'booking_url' => 'dealer.test/book' }) }

    it 'uses the dealership calendar by default even when a rep has one' do
      owner = rep(email: "d#{SecureRandom.hex(3)}@t.test", booking: 'calendly.com/rep')

      expect(Websites::BookingUrl.resolve(company: company, user: owner))
        .to eq('https://dealer.test/book')
    end

    it 'prefers the person when the dealer asked for that' do
      owner = rep(email: "p#{SecureRandom.hex(3)}@t.test", booking: 'calendly.com/rep')
      Setting.set('Company', company.id, 'operational_settings',
                  { 'booking_url' => 'dealer.test/book',
                    'booking_assignment' => { 'mode' => 'assigned_rep' } })

      expect(Websites::BookingUrl.resolve(company: company, user: owner))
        .to eq('https://calendly.com/rep')
    end

    # A rotation landing on someone with no calendar should still offer the
    # dealership's rather than nothing.
    it 'falls back to the dealership when the chosen person has no calendar' do
      owner = rep(email: "n#{SecureRandom.hex(3)}@t.test")
      Setting.set('Company', company.id, 'operational_settings',
                  { 'booking_url' => 'dealer.test/book',
                    'booking_assignment' => { 'mode' => 'assigned_rep' } })

      expect(Websites::BookingUrl.resolve(company: company, user: owner))
        .to eq('https://dealer.test/book')
    end
  end
end

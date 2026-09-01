# frozen_string_literal: true

require 'rails_helper'

# Suspending a company used to set a flag and nothing else: Company#suspended?
# was defined and never called anywhere, so every access check read the USER's
# status instead. Measured in production, a company suspended at 16:42 had three
# of its people authenticating normally 90 seconds later.
RSpec.describe Company, '#access_blocked?' do
  it 'blocks a suspended company' do
    expect(build(:company, status: 'suspended').access_blocked?).to be true
  end

  # Cancelled means the same thing for entitlement. Leaving it open would
  # reopen the same hole under a different name.
  it 'blocks a cancelled company' do
    expect(build(:company, status: 'cancelled').access_blocked?).to be true
  end

  it 'lets an active company through' do
    expect(build(:company, status: 'active').access_blocked?).to be false
  end

  it 'lets a trialling company through' do
    expect(build(:company, status: 'trial').access_blocked?).to be false
  end

  # status is nullable, and a null status must not lock anyone out.
  it 'lets a company with no status set through' do
    expect(build(:company, status: nil).access_blocked?).to be false
  end
end

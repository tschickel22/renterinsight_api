# frozen_string_literal: true

require 'rails_helper'

# A controller that calls authorize_action!('foo', ...) when no Resource row has
# key 'foo' produces a permission nobody can be granted: PermissionService finds
# no matching row, so every RBAC non-admin is denied and no amount of editing the
# permission matrix helps. Admins pass only because they short-circuit earlier,
# which is what hid this for so long.
RSpec.describe 'RBAC resource keys', type: :model do
  before { Resource.seed_defaults }

  # Literal first argument to authorize_action!. Dynamic keys are out of scope;
  # they cannot be checked statically.
  def enforced_keys
    Dir[Rails.root.join('app/controllers/**/*.rb')].flat_map do |path|
      File.read(path).scan(/authorize_action!\(\s*'([a-z_]+)'/).flatten
    end.uniq.sort
  end

  it 'every key a controller enforces has a Resource row behind it' do
    missing = enforced_keys - Resource.pluck(:key)

    expect(missing).to be_empty,
                       "Controllers gate on #{missing.inspect} but no Resource row exists, so no role " \
                       'can ever be granted them. Add them to Resource.seed_defaults.'
  end
end

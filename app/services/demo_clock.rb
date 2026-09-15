# frozen_string_literal: true

# The booth demo's clock. On a demo company with the clock turned on, waits run
# with days as minutes, so a play's 24 hour reply wait passes during a
# conversation at a trade show. It never speeds anything up on a company that is
# not a demo, whatever the setting says.
#
# Applied where a wait starts (workflow waits, reply deadlines, follow-up email
# delays). A wait already running keeps the time it started with.
module DemoClock
  SETTING_KEY = 'demo_clock'
  SCALE = 1440 # a day becomes a minute
  MINIMUM = 5.seconds

  module_function

  def available?(company)
    company.present? && company.is_demo?
  end

  def enabled?(company)
    return false unless available?(company)

    setting = Setting.get('Company', company.id, SETTING_KEY, {})
    setting = {} unless setting.is_a?(Hash)
    ActiveModel::Type::Boolean.new.cast(setting['enabled'] || setting[:enabled]) || false
  end

  def enable!(company, enabled)
    raise ArgumentError, 'The demo clock only runs on demo companies.' unless available?(company)

    Setting.set('Company', company.id, SETTING_KEY, { 'enabled' => enabled ? true : false })
  end

  # A duration as this company's clock runs it.
  def scale(company, duration)
    return duration unless enabled?(company)

    [(duration.to_f / SCALE).seconds, MINIMUM].max
  end
end

class NurtureStepWaitDaysToDecimal < ActiveRecord::Migration[8.0]
  # nurture_steps.wait_days was INTEGER, which silently truncated sub-day
  # delays: the FE lets admins pick "hours" as a unit, but hoursToDays(3)
  # returns Math.round(0.125) = 0, so typing "3 hours" saved as "0 days"
  # and the sequence fired immediately. Widening to decimal(6,3) supports
  # fractional delays without changing the domain (still counted in days).
  def up
    change_column :nurture_steps, :wait_days, :decimal, precision: 6, scale: 3, default: 0, null: false
  end

  def down
    change_column :nurture_steps, :wait_days, :integer, default: 0, null: false
  end
end

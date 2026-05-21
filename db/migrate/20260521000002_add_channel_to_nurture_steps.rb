class AddChannelToNurtureSteps < ActiveRecord::Migration[8.0]
  def change
    add_column :nurture_steps, :channel, :string, default: 'email'
  end
end

class AddTemplateRefToNurtureSteps < ActiveRecord::Migration[7.1]
  def change
    add_reference :nurture_steps, :template, foreign_key: true, null: true
  end
end

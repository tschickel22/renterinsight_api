class AddDescriptionToNurtureSequences < ActiveRecord::Migration[8.0]
  def change
    add_column :nurture_sequences, :description, :text
  end
end

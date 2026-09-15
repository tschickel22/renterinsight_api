class AddAutoStopToNurtureSequences < ActiveRecord::Migration[8.0]
  # Off by default so the sequences dealers already run keep behaving exactly
  # as they do today. Starter plays switch these on.
  def change
    add_column :nurture_sequences, :stop_on_reply, :boolean, default: false, null: false
    add_column :nurture_sequences, :stop_on_conversion, :boolean, default: false, null: false
  end
end

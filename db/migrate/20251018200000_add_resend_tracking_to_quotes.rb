# frozen_string_literal: true

class AddResendTrackingToQuotes < ActiveRecord::Migration[7.0]
  def change
    add_column :quotes, :resend_count, :integer, default: 0, null: false
    add_column :quotes, :last_sent_at, :datetime
    
    # Backfill last_sent_at with sent_at for existing records
    reversible do |dir|
      dir.up do
        execute <<-SQL
          UPDATE quotes 
          SET last_sent_at = sent_at 
          WHERE sent_at IS NOT NULL
        SQL
      end
    end
  end
end

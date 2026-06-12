# frozen_string_literal: true

# Turns "Notes to Manufacturer" from a single overwrite-able text field into an
# append-only, stamped thread. Each entry: { id, body, authorId, authorName,
# authorEmail, createdAt }. The legacy notes_to_manufacturer text column is kept
# for backward compat and folded into the thread as the first entry here.
class AddManufacturerNotesToWarrantyClaims < ActiveRecord::Migration[8.0]
  # Isolated model so this migration is immune to future app-model changes.
  class MigrationWarrantyClaim < ActiveRecord::Base
    self.table_name = 'warranty_claims'
  end

  def up
    unless column_exists?(:warranty_claims, :manufacturer_notes)
      add_column :warranty_claims, :manufacturer_notes, :jsonb, default: [], null: false
    end

    MigrationWarrantyClaim.reset_column_information

    say_with_time 'Backfilling manufacturer_notes from notes_to_manufacturer' do
      count = 0
      MigrationWarrantyClaim.where.not(notes_to_manufacturer: [nil, '']).find_each do |claim|
        next if claim.manufacturer_notes.present?

        ts = (claim.submitted_at || claim.created_at || Time.current).utc.iso8601
        claim.update_columns(manufacturer_notes: [{
          'id' => SecureRandom.uuid,
          'body' => claim.notes_to_manufacturer.to_s,
          'authorId' => nil,
          'authorName' => (claim.submitted_by.presence || 'Dealer'),
          'authorEmail' => nil,
          'createdAt' => ts
        }])
        count += 1
      end
      count
    end
  end

  def down
    remove_column :warranty_claims, :manufacturer_notes
  end
end

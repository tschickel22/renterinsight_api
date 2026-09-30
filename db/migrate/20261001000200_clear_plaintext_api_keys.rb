# frozen_string_literal: true

# Follow-up to HashApiKeysAndAddRequestLogs. That release looks keys up by
# key_digest and has backfilled every row, so the plaintext copy has no reader
# left and is cleared here. Irreversible by design: the whole point is that the
# database no longer holds a usable key. The column itself stays (ignored by
# the model) so this deploy never breaks the release it replaces.
class ClearPlaintextApiKeys < ActiveRecord::Migration[8.0]
  def up
    # Anything written in the rollout gap without a digest gets one first.
    execute <<~SQL
      UPDATE api_keys
      SET key_digest  = encode(sha256(convert_to(key, 'UTF8')), 'hex'),
          key_preview = left(key, 12) || '...' || right(key, 4)
      WHERE key IS NOT NULL AND key_digest IS NULL
    SQL

    remove_index :api_keys, :key, name: 'index_api_keys_on_key'
    execute 'UPDATE api_keys SET key = NULL WHERE key IS NOT NULL'
  end

  def down
    raise ActiveRecord::IrreversibleMigration, 'plaintext API keys cannot be restored'
  end
end

# frozen_string_literal: true

# Fix: Rails `encrypts :api_token` requires the column to be named `api_token`,
# not `api_token_ciphertext`. Rails 8 encrypts/decrypts transparently using the
# same column name as the attribute.
class RenameApiTokenCiphertextToApiToken < ActiveRecord::Migration[8.0]
  def change
    rename_column :champion_lead_feed_configs, :api_token_ciphertext, :api_token
  end
end

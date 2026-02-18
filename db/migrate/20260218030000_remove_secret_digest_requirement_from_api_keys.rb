# frozen_string_literal: true

class RemoveSecretDigestRequirementFromApiKeys < ActiveRecord::Migration[8.0]
  def change
    change_column_null :api_keys, :secret_digest, true
    change_column_default :api_keys, :secret_digest, nil
  end
end

# frozen_string_literal: true

# OAuth 2.1 provider and MCP server (backlog E53), so Claude and ChatGPT can
# connect to DealerTide as one user at one company.
#
# oauth_clients      the AI app (Claude, ChatGPT, Claude Code...). Registered
#                    by the app itself, through dynamic client registration or
#                    a Client ID Metadata Document URL.
# oauth_grants       one user's approval for one client at one company. This
#                    is the "connected app" a user sees and can revoke, and it
#                    is what every token and tool call hangs off.
# oauth_authorization_codes / oauth_tokens
#                    stored as SHA-256 digests only, like api_keys. The
#                    plaintext exists once, in the response that hands it out.
# mcp_tool_calls     audit trail of every tool call, readable per company.
class CreateOauthAndMcpTables < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_clients do |t|
      t.string :client_id, null: false
      t.string :client_name, null: false
      t.jsonb :redirect_uris, null: false, default: []
      t.string :registration_type, null: false # dcr | cimd
      t.string :client_uri
      t.string :logo_uri
      t.jsonb :metadata, null: false, default: {}
      t.datetime :metadata_fetched_at
      t.string :registered_ip
      t.timestamps
    end
    add_index :oauth_clients, :client_id, unique: true

    create_table :oauth_grants do |t|
      t.references :oauth_client, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.references :company, null: false, foreign_key: true
      t.string :scopes, null: false, default: ''
      t.string :resource, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.bigint :revoked_by_user_id
      t.timestamps
    end
    add_index :oauth_grants, [:company_id, :revoked_at]
    add_index :oauth_grants, [:user_id, :oauth_client_id, :company_id], name: 'index_oauth_grants_on_user_client_company'

    create_table :oauth_authorization_codes do |t|
      t.references :oauth_grant, null: false, foreign_key: true
      t.string :code_digest, null: false
      t.string :redirect_uri, null: false
      t.string :code_challenge, null: false
      t.string :scopes, null: false, default: ''
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.datetime :created_at, null: false
    end
    add_index :oauth_authorization_codes, :code_digest, unique: true

    create_table :oauth_tokens do |t|
      t.references :oauth_grant, null: false, foreign_key: true
      t.string :kind, null: false # access | refresh
      t.string :token_digest, null: false
      t.string :scopes, null: false, default: ''
      t.datetime :expires_at, null: false
      t.datetime :used_at
      t.datetime :revoked_at
      t.datetime :created_at, null: false
    end
    add_index :oauth_tokens, :token_digest, unique: true
    add_index :oauth_tokens, [:oauth_grant_id, :kind]

    create_table :mcp_tool_calls do |t|
      t.bigint :oauth_grant_id
      t.bigint :user_id, null: false
      t.bigint :company_id, null: false
      t.string :client_name
      t.string :tool_name, null: false
      t.jsonb :arguments, null: false, default: {}
      t.string :status, null: false # ok | error | denied
      t.integer :result_count
      t.integer :duration_ms
      t.string :error_message
      t.datetime :created_at, null: false
    end
    add_index :mcp_tool_calls, [:company_id, :created_at]
    add_index :mcp_tool_calls, [:oauth_grant_id, :created_at]
    add_index :mcp_tool_calls, [:user_id, :created_at]
  end
end

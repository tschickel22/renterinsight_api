class CreateCompanyDomains < ActiveRecord::Migration[8.0]
  def change
    create_table :company_domains do |t|
      t.references :company, null: false, foreign_key: true, index: true
      t.references :website, null: true, foreign_key: true
      
      # Domain information
      t.string :hostname, null: false # e.g., www.sunshine-rv.com
      t.string :domain_root # e.g., sunshine-rv.com
      
      # Cloudflare for SaaS
      t.string :cloudflare_custom_hostname_id
      t.string :verification_status # pending, active, moved, deleted
      t.jsonb :verification_records, default: {} # DNS records for verification
      
      # SSL certificate status
      t.string :ssl_status # pending, active, expired
      t.datetime :ssl_issued_at
      t.datetime :ssl_expires_at
      
      # DNS configuration
      t.string :cname_target # Cloudflare target for CNAME
      t.datetime :dns_checked_at
      t.string :dns_error
      
      # Status
      t.boolean :active, default: false
      t.datetime :activated_at
      t.datetime :deactivated_at
      
      # Settings
      t.boolean :force_ssl, default: true
      t.boolean :force_www, default: false
      t.string :redirect_type # www_to_non_www, non_www_to_www, none
      
      t.timestamps
    end
    
    add_index :company_domains, :hostname, unique: true
    add_index :company_domains, [:company_id, :active]
    add_index :company_domains, :cloudflare_custom_hostname_id
    add_index :company_domains, :verification_status
  end
end

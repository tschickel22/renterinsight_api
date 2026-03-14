class AddCachedScanToAgreementTemplates < ActiveRecord::Migration[8.0]
  def change
    add_column :agreement_templates, :cached_scan_results, :jsonb, default: nil
    add_column :agreement_templates, :scan_performed_at, :datetime, default: nil
  end
end

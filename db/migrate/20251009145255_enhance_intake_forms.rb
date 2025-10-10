class EnhanceIntakeForms < ActiveRecord::Migration[7.0]
  def change
    unless column_exists?(:intake_forms, :public_id)
      add_column :intake_forms, :public_id, :string
      add_index :intake_forms, :public_id, unique: true
    end
    
    unless column_exists?(:intake_forms, :company_id)
      add_column :intake_forms, :company_id, :bigint
      add_foreign_key :intake_forms, :companies
      add_index :intake_forms, :company_id
    end
    
    add_column :intake_forms, :thank_you_message, :text unless column_exists?(:intake_forms, :thank_you_message)
    add_column :intake_forms, :redirect_url, :string unless column_exists?(:intake_forms, :redirect_url)
    add_column :intake_forms, :submit_button_text, :string, default: 'Submit' unless column_exists?(:intake_forms, :submit_button_text)
    add_column :intake_forms, :submission_count, :integer, default: 0 unless column_exists?(:intake_forms, :submission_count)
    
    add_column :intake_submissions, :ip_address, :string unless column_exists?(:intake_submissions, :ip_address)
    add_column :intake_submissions, :user_agent, :text unless column_exists?(:intake_submissions, :user_agent)
    add_column :intake_submissions, :referrer, :string unless column_exists?(:intake_submissions, :referrer)
    add_column :intake_submissions, :submitted_at, :datetime unless column_exists?(:intake_submissions, :submitted_at)
    add_column :intake_submissions, :lead_created, :boolean, default: false unless column_exists?(:intake_submissions, :lead_created)
    
    unless index_exists?(:intake_submissions, :submitted_at)
      add_index :intake_submissions, :submitted_at
    end
  end
end

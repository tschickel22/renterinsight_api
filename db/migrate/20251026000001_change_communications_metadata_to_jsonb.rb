class ChangeCommunicationsMetadataToJsonb < ActiveRecord::Migration[7.0]
  def up
    # Check if we're using PostgreSQL
    if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      # Convert existing text data to jsonb
      # First, set empty strings and nulls to '{}'
      execute <<-SQL
        UPDATE communications 
        SET metadata = '{}' 
        WHERE metadata IS NULL OR metadata = '';
      SQL
      
      # Change column type from text to jsonb
      change_column :communications, :metadata, :jsonb, using: 'metadata::jsonb', default: {}
    end
  end
  
  def down
    # Check if we're using PostgreSQL
    if ActiveRecord::Base.connection.adapter_name == 'PostgreSQL'
      # Convert back to text
      change_column :communications, :metadata, :text, using: 'metadata::text'
    end
  end
end

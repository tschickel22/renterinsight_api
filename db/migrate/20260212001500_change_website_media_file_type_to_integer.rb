class ChangeWebsiteMediaFileTypeToInteger < ActiveRecord::Migration[8.0]
  def up
    # Step 1: Add temporary integer column with default value
    add_column :website_media, :file_type_int, :integer, default: 3  # 3 = 'other'
    
    # Step 2: Backfill existing records based on mime_type
    WebsiteMedia.where(is_deleted: [false, nil]).find_each do |media|
      # Determine correct integer value based on mime_type
      integer_value = if media.mime_type&.start_with?('image/')
        0  # image
      elsif media.mime_type&.start_with?('video/')
        1  # video
      elsif media.mime_type&.match?(/(pdf|msword|wordprocessingml|spreadsheet|presentation)/)
        2  # document
      else
        3  # other
      end
      
      # Update the temporary integer column
      media.update_column(:file_type_int, integer_value)
    end
    
    # Step 3: Remove old string column
    remove_column :website_media, :file_type
    
    # Step 4: Rename temporary column to file_type
    rename_column :website_media, :file_type_int, :file_type
    
    # Step 5: Add index on new integer column
    add_index :website_media, :file_type unless index_exists?(:website_media, :file_type)
  end
  
  def down
    # Reverse: integer back to string
    add_column :website_media, :file_type_str, :string
    
    # Convert integer values back to string representations
    WebsiteMedia.find_each do |media|
      string_value = case media.file_type
      when 0 then 'image'
      when 1 then 'video'
      when 2 then 'document'
      when 3 then 'other'
      else 'other'
      end
      media.update_column(:file_type_str, string_value)
    end
    
    remove_column :website_media, :file_type
    rename_column :website_media, :file_type_str, :file_type
    add_index :website_media, :file_type unless index_exists?(:website_media, :file_type)
  end
end

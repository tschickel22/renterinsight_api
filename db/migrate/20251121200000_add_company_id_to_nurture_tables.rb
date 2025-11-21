class AddCompanyIdToNurtureTables < ActiveRecord::Migration[8.0]
  def change
    # Add company_id to nurture_sequences
    unless column_exists?(:nurture_sequences, :company_id)
      add_reference :nurture_sequences, :company, null: true, foreign_key: true, index: true
    end

    # Add company_id to nurture_enrollments (for denormalized access)
    unless column_exists?(:nurture_enrollments, :company_id)
      add_reference :nurture_enrollments, :company, null: true, foreign_key: true, index: true
    end
  end
end

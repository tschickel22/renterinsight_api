# Option groups defaulted to single choice, so the groups a publish created
# (Decatur's) cleared every other pick in a section: choosing carpet removed
# the linoleum. Nothing chooses single on purpose; every group made by hand
# or by the regroup was multiple.
class OptionGroupsDefaultToMultiple < ActiveRecord::Migration[8.0]
  def up
    change_column_default :catalog_option_groups, :selection_type, from: 'single', to: 'multiple'
    execute "UPDATE catalog_option_groups SET selection_type = 'multiple' WHERE selection_type = 'single'"
  end

  def down
    change_column_default :catalog_option_groups, :selection_type, from: 'multiple', to: 'single'
  end
end

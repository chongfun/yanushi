class RenameEmailAddressToEmailOnUsers < ActiveRecord::Migration[8.1]
  def change
    rename_column :users, :email_address, :email
  end
end

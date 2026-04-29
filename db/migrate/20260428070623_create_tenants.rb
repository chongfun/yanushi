class CreateTenants < ActiveRecord::Migration[8.1]
  def change
    create_table :tenants do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name
      t.string :mailing_address
      t.string :phone_number
      t.string :email_address

      t.timestamps
    end
  end
end

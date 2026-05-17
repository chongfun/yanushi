class CreateEmailConfigurations < ActiveRecord::Migration[8.1]
  def change
    create_table :email_configurations do |t|
      t.references :user,                    null: false, foreign_key: true, index: { unique: true }
      t.string     :provider,                null: false, default: "gmail_api"
      t.string     :gmail_address,           null: false
      t.string     :google_refresh_token,    null: false
      t.string     :google_access_token,     null: false
      t.datetime   :google_token_expires_at, null: false
      t.boolean    :enabled,                 null: false, default: true
      t.datetime   :last_polled_at
      t.timestamps
    end
  end
end

# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_17_000005) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "email_configurations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.boolean "enabled", default: true, null: false
    t.integer "imap_port", default: 993, null: false
    t.string "imap_server", null: false
    t.datetime "last_polled_at"
    t.string "mailbox", default: "INBOX", null: false
    t.string "password", null: false
    t.boolean "ssl", default: true, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.string "username", null: false
    t.index ["user_id"], name: "index_email_configurations_on_user_id", unique: true
  end

  create_table "expenses", force: :cascade do |t|
    t.decimal "amount"
    t.string "category"
    t.datetime "created_at", null: false
    t.string "description"
    t.date "expense_date"
    t.integer "rental_property_id", null: false
    t.datetime "updated_at", null: false
    t.index ["rental_property_id"], name: "index_expenses_on_rental_property_id"
  end

  create_table "lease_tenants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "lease_id", null: false
    t.integer "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["lease_id"], name: "index_lease_tenants_on_lease_id"
    t.index ["tenant_id"], name: "index_lease_tenants_on_tenant_id"
  end

  create_table "leases", force: :cascade do |t|
    t.decimal "annual_rental_amount"
    t.date "commencement_date"
    t.datetime "created_at", null: false
    t.integer "late_period_days"
    t.integer "lease_type"
    t.integer "rental_property_id", null: false
    t.decimal "security_deposit"
    t.date "termination_date"
    t.datetime "updated_at", null: false
    t.index ["rental_property_id"], name: "index_leases_on_rental_property_id"
  end

  create_table "notifications", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "message"
    t.string "notification_type", null: false
    t.bigint "payment_email_id"
    t.boolean "read", default: false, null: false
    t.string "title", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["payment_email_id"], name: "index_notifications_on_payment_email_id"
    t.index ["user_id"], name: "index_notifications_on_user_id"
  end

  create_table "payment_emails", force: :cascade do |t|
    t.decimal "amount"
    t.datetime "created_at", null: false
    t.string "error_message"
    t.string "message_id", null: false
    t.date "payment_date"
    t.string "provider"
    t.text "raw_body"
    t.bigint "rent_payment_id"
    t.string "sender_name"
    t.string "status", default: "pending", null: false
    t.string "transaction_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.bigint "utility_payment_id"
    t.index ["rent_payment_id"], name: "index_payment_emails_on_rent_payment_id"
    t.index ["user_id", "message_id"], name: "index_payment_emails_on_user_id_and_message_id", unique: true
    t.index ["user_id"], name: "index_payment_emails_on_user_id"
    t.index ["utility_payment_id"], name: "index_payment_emails_on_utility_payment_id"
  end

  create_table "rent_payments", force: :cascade do |t|
    t.decimal "amount"
    t.datetime "created_at", null: false
    t.date "payment_date"
    t.string "payment_method"
    t.integer "scheduled_rent_id", null: false
    t.string "transaction_number"
    t.datetime "updated_at", null: false
    t.index ["scheduled_rent_id"], name: "index_rent_payments_on_scheduled_rent_id"
  end

  create_table "rental_properties", force: :cascade do |t|
    t.string "address"
    t.datetime "created_at", null: false
    t.integer "property_type"
    t.integer "square_footage"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_rental_properties_on_user_id"
  end

  create_table "scheduled_rents", force: :cascade do |t|
    t.decimal "amount"
    t.datetime "created_at", null: false
    t.date "due_date"
    t.integer "lease_id", null: false
    t.boolean "paid", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["lease_id"], name: "index_scheduled_rents_on_lease_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "tenant_aliases", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id", "name"], name: "index_tenant_aliases_on_tenant_id_and_name", unique: true
    t.index ["tenant_id"], name: "index_tenant_aliases_on_tenant_id"
  end

  create_table "tenants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email_address"
    t.string "mailing_address"
    t.string "name"
    t.string "phone_number"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_tenants_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "password_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  create_table "utility_payments", force: :cascade do |t|
    t.decimal "amount"
    t.datetime "created_at", null: false
    t.bigint "expense_id"
    t.integer "lease_id", null: false
    t.date "payment_date"
    t.string "payment_method"
    t.string "transaction_number"
    t.datetime "updated_at", null: false
    t.index ["expense_id"], name: "index_utility_payments_on_expense_id"
    t.index ["lease_id"], name: "index_utility_payments_on_lease_id"
  end

  add_foreign_key "email_configurations", "users"
  add_foreign_key "expenses", "rental_properties"
  add_foreign_key "lease_tenants", "leases"
  add_foreign_key "lease_tenants", "tenants"
  add_foreign_key "leases", "rental_properties"
  add_foreign_key "notifications", "payment_emails"
  add_foreign_key "notifications", "users"
  add_foreign_key "payment_emails", "rent_payments"
  add_foreign_key "payment_emails", "users"
  add_foreign_key "payment_emails", "utility_payments"
  add_foreign_key "rent_payments", "scheduled_rents"
  add_foreign_key "rental_properties", "users"
  add_foreign_key "scheduled_rents", "leases"
  add_foreign_key "sessions", "users"
  add_foreign_key "tenant_aliases", "tenants"
  add_foreign_key "tenants", "users"
  add_foreign_key "utility_payments", "expenses"
  add_foreign_key "utility_payments", "leases"
end

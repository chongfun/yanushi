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

ActiveRecord::Schema[8.1].define(version: 2026_05_25_000001) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "expenses", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2
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
    t.decimal "annual_rental_amount", precision: 12, scale: 2
    t.date "commencement_date"
    t.datetime "created_at", null: false
    t.integer "late_period_days"
    t.integer "lease_type"
    t.integer "rental_property_id", null: false
    t.decimal "security_deposit", precision: 12, scale: 2
    t.date "termination_date"
    t.datetime "updated_at", null: false
    t.index ["rental_property_id"], name: "index_leases_on_rental_property_id"
  end

  create_table "payment_documents", force: :cascade do |t|
    t.string "attachment_content_type"
    t.binary "attachment_file"
    t.string "attachment_filename"
    t.datetime "created_at", null: false
    t.text "error_message"
    t.string "status", default: "processing", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_payment_documents_on_user_id"
  end

  create_table "payment_ingestions", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2
    t.datetime "created_at", null: false
    t.text "error_message"
    t.bigint "lease_id"
    t.string "payer_name"
    t.string "payer_username"
    t.date "payment_date"
    t.bigint "payment_document_id"
    t.string "payment_method"
    t.text "raw_text"
    t.string "receipt_type"
    t.string "source", null: false
    t.string "status", default: "pending", null: false
    t.bigint "tenant_id"
    t.bigint "tenant_payment_id"
    t.string "transaction_number"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["lease_id"], name: "index_payment_ingestions_on_lease_id"
    t.index ["payment_document_id"], name: "index_payment_ingestions_on_payment_document_id"
    t.index ["tenant_id"], name: "index_payment_ingestions_on_tenant_id"
    t.index ["tenant_payment_id"], name: "index_payment_ingestions_on_tenant_payment_id"
    t.index ["user_id", "payment_method", "transaction_number"], name: "idx_payment_ingestions_dup_check"
    t.index ["user_id"], name: "index_payment_ingestions_on_user_id"
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
    t.decimal "amount", precision: 12, scale: 2
    t.datetime "created_at", null: false
    t.date "due_date"
    t.integer "lease_id", null: false
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
    t.string "alias_name", null: false
    t.datetime "created_at", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index "tenant_id, lower((alias_name)::text)", name: "index_tenant_aliases_on_tenant_id_and_lower_alias_name", unique: true
    t.index ["tenant_id"], name: "index_tenant_aliases_on_tenant_id"
  end

  create_table "tenant_charges", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.date "charge_date", null: false
    t.datetime "created_at", null: false
    t.string "description"
    t.bigint "expense_id", null: false
    t.bigint "lease_id", null: false
    t.datetime "updated_at", null: false
    t.index ["expense_id"], name: "index_tenant_charges_on_expense_id"
    t.index ["lease_id"], name: "index_tenant_charges_on_lease_id"
  end

  create_table "tenant_payments", force: :cascade do |t|
    t.decimal "amount", precision: 12, scale: 2, null: false
    t.datetime "created_at", null: false
    t.bigint "lease_id", null: false
    t.date "payment_date", null: false
    t.string "payment_method", null: false
    t.string "transaction_number"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["lease_id"], name: "index_tenant_payments_on_lease_id"
    t.index ["user_id", "payment_method", "transaction_number"], name: "index_tenant_payments_on_user_payment_method_transaction_number", unique: true, where: "(transaction_number IS NOT NULL)"
    t.index ["user_id"], name: "index_tenant_payments_on_user_id"
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
    t.string "timezone", default: "UTC", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "expenses", "rental_properties"
  add_foreign_key "lease_tenants", "leases"
  add_foreign_key "lease_tenants", "tenants"
  add_foreign_key "leases", "rental_properties"
  add_foreign_key "payment_documents", "users"
  add_foreign_key "payment_ingestions", "leases"
  add_foreign_key "payment_ingestions", "payment_documents"
  add_foreign_key "payment_ingestions", "tenant_payments"
  add_foreign_key "payment_ingestions", "tenants"
  add_foreign_key "payment_ingestions", "users"
  add_foreign_key "rental_properties", "users"
  add_foreign_key "scheduled_rents", "leases"
  add_foreign_key "sessions", "users"
  add_foreign_key "tenant_aliases", "tenants"
  add_foreign_key "tenant_charges", "expenses"
  add_foreign_key "tenant_charges", "leases"
  add_foreign_key "tenant_payments", "leases"
  add_foreign_key "tenant_payments", "users"
  add_foreign_key "tenants", "users"
end
